//! USB Local HTTPS server (`192.168.225.1:8577`) — 100% compatible with SkySIM iOS USB local
//! transport (`protocol/v2/USB_LOCAL.md` & Go `internal/cloud/usb.go`).

use crate::cloud::CloudAgent;
use crate::control::{CommandRequest, ParseCommandError};
use crate::http_lite::{read_http_request, write_http_response, HttpRequest, HttpResponse};
use crate::identity::{is_valid_uuid_v4, uuid_v4};
use crate::journal::{now_rfc3339, parse_rfc3339};
use crate::provision::is_hex32;
use crate::rtc::MediaSessionConfig;
use crate::strict_json;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use rcgen::{CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, KeyPair, KeyUsagePurpose, SanType};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::ServerConfig;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use subtle::ConstantTimeEq;
use ::time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time};
use tokio::net::TcpListener;
use tokio::sync::watch;
use tokio_rustls::TlsAcceptor;
use x509_parser::certificate::X509Certificate;
use x509_parser::prelude::FromDer;

type HmacSha256 = Hmac<Sha256>;

const MAX_SDP: usize = 32768;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsbAuthorization {
    pub server_id: String,
    pub module_id: String,
    pub client_installation_id: String,
    pub api_origin: String,
    pub certificate_der_base64: String,
    pub token: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UsbGrant {
    token: String,
    expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UsbRecord {
    #[serde(rename = "Request")]
    request: CommandRequest,
    #[serde(rename = "Client")]
    client: String,
    #[serde(rename = "Generation")]
    generation: String,
}

struct UsbMediaEntry {
    client: String,
    call_id: String,
    generation: String,
    request_id: String,
    session_id: String,
    expires_at: Instant,
    used: bool,
}

struct UsbInner {
    nonces: HashMap<String, Instant>,
    grants: HashMap<String, UsbGrant>,
    records: HashMap<String, UsbRecord>,
    sessions: HashMap<String, UsbMediaEntry>,
}

pub struct UsbServer {
    pub address: SocketAddr,
    pub ipv4: Ipv4Addr,
    pub origin: String,
    pub epoch: String,
    grants_path: PathBuf,
    commands_path: PathBuf,
    cert_der: Vec<u8>,
    tls_acceptor: TlsAcceptor,
    inner: Mutex<UsbInner>,
}

fn atomic_save(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let tmp = PathBuf::from(format!("{}.tmp", path.display()));
    {
        let mut f = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        f.write_all(bytes).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
    }
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn load_or_generate_usb_tls(
    dir: &Path,
    module_id: &str,
    ip: Ipv4Addr,
) -> Result<(Vec<u8>, Arc<ServerConfig>), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let pem_path = dir.join("usb-tls.pem");
    let mut need_gen = !pem_path.exists();
    let mut raw_pem = Vec::new();

    if !need_gen {
        raw_pem = fs::read(&pem_path).map_err(|e| e.to_string())?;
        // Check if existing cert was minted with 1970/1980 clock and is now expired once RTC synced.
        let mut cur = std::io::Cursor::new(&raw_pem);
        if let Some(Ok(cert)) = rustls_pemfile::certs(&mut cur).next() {
            if let Ok((_, parsed)) = X509Certificate::from_der(cert.as_ref()) {
                let now = OffsetDateTime::now_utc();
                if now.year() >= 2025 && now >= parsed.validity().not_after.to_datetime() {
                    need_gen = true;
                }
            }
        } else {
            need_gen = true;
        }
    }

    if need_gen {
        let key_pair = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
            .map_err(|e| format!("usb_key_gen: {e}"))?;
        let mut params = CertificateParams::default();
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, module_id);
        params.distinguished_name = dn;
        params.subject_alt_names = vec![SanType::IpAddress(IpAddr::V4(ip))];
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        let now = OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::minutes(5);
        params.not_after = if now.year() < 2025 {
            PrimitiveDateTime::new(
                Date::from_calendar_date(2040, Month::January, 1).unwrap(),
                Time::MIDNIGHT,
            )
            .assume_utc()
        } else {
            now + time::Duration::days(3650)
        };
        let cert = params
            .self_signed(&key_pair)
            .map_err(|e| format!("usb_cert_sign: {e}"))?;
        let combined = format!("{}{}", cert.pem(), key_pair.serialize_pem());
        atomic_save(&pem_path, combined.as_bytes())?;
        raw_pem = combined.into_bytes();
    }

    let mut cert_cur = std::io::Cursor::new(&raw_pem);
    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut cert_cur)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("usb_cert_parse: {e}"))?;
    let cert_der = certs
        .first()
        .ok_or_else(|| "usb_cert_empty".to_string())?
        .as_ref()
        .to_vec();

    let mut key_cur = std::io::Cursor::new(&raw_pem);
    let key: PrivateKeyDer<'static> = rustls_pemfile::private_key(&mut key_cur)
        .map_err(|e| format!("usb_key_parse: {e}"))?
        .ok_or_else(|| "usb_key_missing".to_string())?;

    let provider = Arc::new(rustls_rustcrypto::provider());
    let server_cfg = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("usb_tls_proto: {e}"))?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| format!("usb_tls_cfg: {e}"))?;

    Ok((cert_der, Arc::new(server_cfg)))
}

impl UsbServer {
    pub fn configure(
        address_str: &str,
        config_dir: &Path,
        module_id: &str,
    ) -> Result<Arc<Self>, String> {
        let addr: SocketAddr = address_str
            .parse()
            .map_err(|_| "usb_address_invalid".to_string())?;
        let SocketAddr::V4(v4) = addr else {
            return Err("usb_ipv4_only".into());
        };
        let ipv4 = *v4.ip();
        if !ipv4.is_private() || v4.port() == 0 {
            return Err("usb_address_not_private".into());
        }
        let (cert_der, server_cfg) = load_or_generate_usb_tls(config_dir, module_id, ipv4)?;
        let epoch = uuid_v4()?;
        let grants_path = config_dir.join("usb-grants.json");
        let commands_path = config_dir.join("usb-commands.json");

        let grants: HashMap<String, UsbGrant> = match fs::read(&grants_path) {
            Ok(b) if b.len() <= 16384 => serde_json::from_slice(&b).unwrap_or_default(),
            Ok(_) => return Err("usb_grants_too_large".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(e.to_string()),
        };

        let records: HashMap<String, UsbRecord> = match fs::read(&commands_path) {
            Ok(b) if b.len() <= 512 * 1024 => serde_json::from_slice(&b).unwrap_or_default(),
            Ok(_) => return Err("usb_commands_too_large".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(e.to_string()),
        };

        Ok(Arc::new(Self {
            address: addr,
            ipv4,
            origin: format!("https://{address_str}"),
            epoch,
            grants_path,
            commands_path,
            cert_der,
            tls_acceptor: TlsAcceptor::from(server_cfg),
            inner: Mutex::new(UsbInner {
                nonces: HashMap::new(),
                grants,
                records,
                sessions: HashMap::new(),
            }),
        }))
    }

    pub fn existing_command_clients(&self) -> Vec<(String, String)> {
        self.inner
            .lock()
            .unwrap()
            .records
            .iter()
            .map(|(id, r)| (id.clone(), r.client.clone()))
            .collect()
    }

    pub fn authorize(
        &self,
        server_id: &str,
        module_id: &str,
        client: &str,
        expires: &str,
    ) -> Result<UsbAuthorization, String> {
        if !is_valid_uuid_v4(client) {
            return Err("invalid_client".into());
        }
        let exp = parse_rfc3339(expires).ok_or_else(|| "invalid_expiry".to_string())?;
        let now = OffsetDateTime::now_utc();
        let rem = exp - now;
        if rem.is_negative() || rem.is_zero() || rem > time::Duration::hours(24) + time::Duration::seconds(5) {
            return Err("invalid_expiry".into());
        }

        let mut g = self.inner.lock().unwrap();
        g.grants.retain(|_, gr| {
            parse_rfc3339(&gr.expires_at).is_some_and(|t| t > now)
        });
        let token = if let Some(existing) = g.grants.get(client) {
            existing.token.clone()
        } else {
            let mut raw = [0u8; 32];
            getrandom::getrandom(&mut raw).map_err(|e| e.to_string())?;
            hex::encode(raw)
        };
        let mut next = HashMap::new();
        next.insert(
            client.to_string(),
            UsbGrant {
                token: token.clone(),
                expires_at: expires.to_string(),
            },
        );
        let bytes = serde_json::to_vec(&next).map_err(|e| e.to_string())?;
        atomic_save(&self.grants_path, &bytes)?;
        g.grants = next;

        let b64 = base64::engine::general_purpose::STANDARD;
        Ok(UsbAuthorization {
            server_id: server_id.to_string(),
            module_id: module_id.to_string(),
            client_installation_id: client.to_string(),
            api_origin: self.origin.clone(),
            certificate_der_base64: b64.encode(&self.cert_der),
            token,
            expires_at: expires.to_string(),
        })
    }

    pub fn revoke(&self, client: &str) -> Result<(), String> {
        let mut g = self.inner.lock().unwrap();
        g.grants.remove(client);
        let bytes = serde_json::to_vec(&g.grants).map_err(|e| e.to_string())?;
        atomic_save(&self.grants_path, &bytes)
    }

    fn authenticate(&self, req: &HttpRequest) -> Option<String> {
        let auth = req.header("authorization");
        let token = auth.strip_prefix("Bearer ")?;
        if !is_hex32(token) {
            return None;
        }
        let stamp = req.header("x-airsim-timestamp");
        let nonce = req.header("x-airsim-nonce");
        let sig = req.header("x-airsim-signature");
        let secs: i64 = stamp.parse().ok()?;
        if !is_hex32(nonce) || !is_hex32(sig) {
            return None;
        }
        let now_utc = OffsetDateTime::now_utc();
        let delta = now_utc.unix_timestamp() - secs;
        if !(-30..=30).contains(&delta) {
            return None;
        }
        if req.body.len() > 2 * MAX_SDP {
            return None;
        }
        let key = hex::decode(token).ok()?;
        let mut mac = HmacSha256::new_from_slice(&key).ok()?;
        mac.update(format!("{stamp}\n{nonce}\n{}\n{}\n", req.method, req.target).as_bytes());
        mac.update(&req.body);
        let expected = mac.finalize().into_bytes();
        let supplied = hex::decode(sig).ok()?;
        if expected.as_slice().ct_eq(supplied.as_slice()).unwrap_u8() != 1 {
            return None;
        }

        let mut g = self.inner.lock().unwrap();
        let now_mono = Instant::now();
        g.nonces.retain(|_, exp| now_mono < *exp);
        if g.nonces.contains_key(nonce) || g.nonces.len() >= 4096 {
            return None;
        }
        let matched = g.grants.iter().find_map(|(client_id, gr)| {
            let exp = parse_rfc3339(&gr.expires_at)?;
            if now_utc < exp && token.as_bytes().ct_eq(gr.token.as_bytes()).unwrap_u8() == 1 {
                Some(client_id.clone())
            } else {
                None
            }
        });
        if let Some(client_id) = matched {
            g.nonces
                .insert(nonce.to_string(), now_mono + Duration::from_secs(61));
            return Some(client_id);
        }
        None
    }

    pub async fn serve(
        self: Arc<Self>,
        agent: Arc<CloudAgent>,
        mut shutdown: watch::Receiver<bool>,
    ) {
        loop {
            if *shutdown.borrow() {
                return;
            }
            let listener = match TcpListener::bind(self.address).await {
                Ok(l) => l,
                Err(_) => {
                    tokio::select! {
                        _ = shutdown.changed() => return,
                        _ = tokio::time::sleep(Duration::from_secs(1)) => continue,
                    }
                }
            };

            loop {
                tokio::select! {
                    _ = shutdown.changed() => return,
                    accepted = listener.accept() => {
                        match accepted {
                            Ok((stream, _)) => {
                                let srv = self.clone();
                                let ag = agent.clone();
                                tokio::spawn(async move {
                                    let Ok(tls) = tokio::time::timeout(
                                        Duration::from_secs(5),
                                        srv.tls_acceptor.accept(stream),
                                    ).await.and_then(|r| Ok(r)) else {
                                        return;
                                    };
                                    let Ok(mut tls) = tls else {
                                        return;
                                    };
                                    loop {
                                        match read_http_request(&mut tls, Duration::from_secs(15)).await {
                                            Ok(Some(req)) => {
                                                let keep = req.header("connection").eq_ignore_ascii_case("keep-alive");
                                                let resp = srv.handle_request(&ag, req).await;
                                                if write_http_response(&mut tls, &resp, keep).await.is_err() || !keep {
                                                    break;
                                                }
                                            }
                                            _ => break,
                                        }
                                    }
                                });
                            }
                            Err(_) => break,
                        }
                    }
                }
            }
        }
    }

    async fn handle_request(&self, agent: &Arc<CloudAgent>, req: HttpRequest) -> HttpResponse {
        let Some(client) = self.authenticate(&req) else {
            return HttpResponse::empty(401);
        };
        let module_id = agent.provisioner.identity.module_id.clone();
        let server_id = agent.provisioner.view().server_id;

        if req.path == "/v2/modules" && req.method == "GET" {
            let st = agent.control.status();
            return HttpResponse::json(
                200,
                &json!({
                    "server_id": server_id,
                    "modules": [{
                        "module_id": module_id,
                        "online": true,
                        "last_seen": now_rfc3339(),
                        "agent_boot_id": st.agent_boot_id,
                        "backend_epoch": st.backend_epoch,
                        "connection_epoch": self.epoch,
                        "signal": agent.state.signal(),
                    }]
                }),
            );
        }

        let prefix = format!("/v2/modules/{module_id}/");
        let Some(rest) = req.path.strip_prefix(&prefix) else {
            return HttpResponse::empty(404);
        };
        let parts: Vec<&str> = rest.split('/').collect();

        if parts.len() >= 3 && parts[0] == "calls" && parts[2] == "media-sessions" {
            return self.handle_media(agent, &req, &client, &parts).await;
        }

        if parts.len() == 1 && req.method == "GET" {
            match parts[0] {
                "snapshot" => {
                    let st = agent.control.status();
                    let calls = agent.control.calls_view();
                    let audio = agent.control.audio_view();
                    let snap = json!({
                        "agent_boot_id": st.agent_boot_id,
                        "backend_epoch": st.backend_epoch,
                        "observed_at": now_rfc3339(),
                        "control": st,
                        "calls": calls,
                        "audio": audio,
                        "signal": agent.state.signal(),
                    });
                    return HttpResponse::json(
                        200,
                        &json!({
                            "server_id": server_id,
                            "module_id": module_id,
                            "online": true,
                            "last_seen": now_rfc3339(),
                            "connection_epoch": self.epoch,
                            "snapshot": snap,
                        }),
                    );
                }
                "messages" => {
                    let msgs = agent.control.messages_view(true);
                    return HttpResponse::json(
                        200,
                        &json!({
                            "server_id": server_id,
                            "module_id": module_id,
                            "agent_boot_id": msgs.agent_boot_id,
                            "backend_epoch": msgs.backend_epoch,
                            "online": true,
                            "inbox_gap": msgs.inbox_gap,
                            "inbox_dropped": msgs.inbox_dropped,
                            "messages": msgs.messages,
                        }),
                    );
                }
                _ => {}
            }
        }

        if parts.len() == 1 && parts[0] == "commands" && req.method == "POST" {
            return self.handle_command(agent, &req, &client);
        }
        if parts.len() == 2 && parts[0] == "commands" && req.method == "GET" {
            return self.handle_receipt(agent, &client, parts[1]);
        }

        HttpResponse::empty(404)
    }

    fn format_record(&self, agent: &Arc<CloudAgent>, rec: &UsbRecord) -> (Option<Value>, u16) {
        let Some(rcpt) = agent.control.command_receipt(&rec.request.command_id) else {
            return (
                Some(json!({
                    "command_id": rec.request.command_id,
                    "state": "outcome_unknown",
                    "generation": rec.generation,
                    "receipt": Value::Null,
                })),
                200,
            );
        };
        agent.update_claim(&rec.request, &rcpt.state, &rcpt.call_id);
        if matches!(rcpt.state.as_str(), "accepted" | "observed")
            && is_valid_uuid_v4(&rcpt.call_id)
            && matches!(rec.request.action.as_str(), "call.dial" | "call.answer")
        {
            agent.set_call_owner(
                &rcpt.call_id,
                &rec.client,
                &rec.generation,
                &rec.request.agent_boot_id,
                &rec.request.backend_epoch,
            );
        }
        let server_state = match rcpt.state.as_str() {
            "prepared" => "pending",
            "dispatched" => "dispatched",
            "outcome_unknown" => "outcome_unknown",
            _ => "completed",
        };
        (
            Some(json!({
                "command_id": rec.request.command_id,
                "state": server_state,
                "generation": rec.generation,
                "receipt": rcpt,
            })),
            200,
        )
    }

    fn handle_command(
        &self,
        agent: &Arc<CloudAgent>,
        req: &HttpRequest,
        client: &str,
    ) -> HttpResponse {
        #[derive(Deserialize)]
        struct Body {
            connection_epoch: String,
            command: Value,
        }
        let Ok(body) = strict_json::decode_exact_csv::<Body>(&req.body, "connection_epoch,command", "")
        else {
            return HttpResponse::empty(400);
        };
        let cmd_bytes = serde_json::to_vec(&body.command).unwrap_or_default();
        let cmd_req = match CommandRequest::parse(&cmd_bytes) {
            Ok(r) => r,
            Err(ParseCommandError::UnsupportedAction) => return HttpResponse::empty(404),
            Err(_) => return HttpResponse::empty(400),
        };
        if body.connection_epoch != self.epoch {
            return HttpResponse::empty(409);
        }

        let existing = self.inner.lock().unwrap().records.get(&cmd_req.command_id).cloned();
        if let Some(old) = existing {
            if old.client != client {
                return HttpResponse::empty(409);
            }
            if !agent.reserve_command(&cmd_req, client, "usb") {
                return HttpResponse::empty(409);
            }
            let (_, code) = agent.control.submit(cmd_req);
            if code != 200 && code != 202 {
                return HttpResponse::empty(code);
            }
            let (val, code) = self.format_record(agent, &old);
            return match val {
                Some(v) => HttpResponse::json(code, &v),
                None => HttpResponse::empty(code),
            };
        }

        let generation = match uuid_v4() {
            Ok(id) => id,
            Err(_) => return HttpResponse::empty(503),
        };
        let rec = UsbRecord {
            request: cmd_req.clone(),
            client: client.to_string(),
            generation,
        };
        {
            let mut g = self.inner.lock().unwrap();
            if g.records.len() >= 1024 {
                return HttpResponse::empty(429);
            }
            g.records.insert(cmd_req.command_id.clone(), rec.clone());
            if let Ok(encoded) = serde_json::to_vec(&g.records) {
                if atomic_save(&self.commands_path, &encoded).is_err() {
                    g.records.remove(&cmd_req.command_id);
                    return HttpResponse::empty(503);
                }
            }
        }
        if !agent.reserve_command(&cmd_req, client, "usb") {
            self.inner.lock().unwrap().records.remove(&cmd_req.command_id);
            return HttpResponse::empty(409);
        }
        let (_, code) = agent.control.submit(cmd_req.clone());
        if code != 200 && code != 202 {
            agent.reject_claim(&cmd_req, code);
            return HttpResponse::empty(code);
        }
        let (val, code) = self.format_record(agent, &rec);
        match val {
            Some(v) => HttpResponse::json(code, &v),
            None => HttpResponse::empty(code),
        }
    }

    fn handle_receipt(&self, agent: &Arc<CloudAgent>, client: &str, id: &str) -> HttpResponse {
        let rec = self.inner.lock().unwrap().records.get(id).cloned();
        let Some(rec) = rec else {
            return HttpResponse::empty(404);
        };
        if rec.client != client {
            return HttpResponse::empty(404);
        }
        let (val, code) = self.format_record(agent, &rec);
        match val {
            Some(v) => HttpResponse::json(code, &v),
            None => HttpResponse::empty(code),
        }
    }

    async fn handle_media(
        &self,
        agent: &Arc<CloudAgent>,
        req: &HttpRequest,
        client: &str,
        parts: &[&str],
    ) -> HttpResponse {
        let call_id = parts[1];
        if !is_valid_uuid_v4(call_id) {
            return HttpResponse::empty(404);
        }

        if parts.len() == 4 && req.method == "DELETE" {
            let sid = parts[3];
            let found = {
                let mut g = self.inner.lock().unwrap();
                if let Some(m) = g.sessions.get_mut(sid) {
                    if m.client == client && m.call_id == call_id {
                        m.used = true;
                        true
                    } else {
                        false
                    }
                } else {
                    false
                }
            };
            if !found {
                return HttpResponse::empty(404);
            }
            agent.stop_bridge(sid);
            return HttpResponse::empty(204);
        }

        if parts.len() == 3 && req.method == "POST" {
            #[derive(Deserialize)]
            struct CreateBody {
                request_id: String,
                connection_epoch: String,
                generation: String,
                codec: String,
            }
            let Ok(b) = strict_json::decode_exact_csv::<CreateBody>(
                &req.body,
                "request_id,connection_epoch,generation,codec",
                "",
            ) else {
                return HttpResponse::empty(400);
            };
            if b.codec != "opus" || !is_valid_uuid_v4(&b.request_id) || !is_valid_uuid_v4(&b.generation) {
                return HttpResponse::empty(400);
            }
            if b.connection_epoch != self.epoch {
                return HttpResponse::empty(409);
            }
            if !agent.is_usb_call_owner(client, call_id, &b.generation) {
                return HttpResponse::empty(409);
            }
            let Ok(sid) = uuid_v4() else {
                return HttpResponse::empty(503);
            };
            let exp_utc = OffsetDateTime::now_utc() + time::Duration::seconds(15);
            {
                let mut g = self.inner.lock().unwrap();
                g.sessions.insert(
                    sid.clone(),
                    UsbMediaEntry {
                        client: client.to_string(),
                        call_id: call_id.to_string(),
                        generation: b.generation.clone(),
                        request_id: b.request_id.clone(),
                        session_id: sid.clone(),
                        expires_at: Instant::now() + Duration::from_secs(15),
                        used: false,
                    },
                );
            }
            return HttpResponse::json(
                201,
                &json!({
                    "session_id": sid,
                    "call_id": call_id,
                    "codec": "opus",
                    "expires_at": exp_utc.format(&time::format_description::well_known::Rfc3339).unwrap_or_default(),
                    "ice_servers": [],
                    "ice_transport_policy": "all",
                }),
            );
        }

        if parts.len() == 5 && parts[4] == "offer" && req.method == "POST" {
            let sid = parts[3];
            #[derive(Deserialize)]
            struct OfferBody {
                offer: String,
            }
            let Ok(b) = strict_json::decode_exact_csv::<OfferBody>(&req.body, "offer", "") else {
                return HttpResponse::empty(400);
            };
            if b.offer.len() > MAX_SDP || !b.offer.starts_with("v=0\r\n") {
                return HttpResponse::empty(400);
            }
            let entry = {
                let mut g = self.inner.lock().unwrap();
                match g.sessions.get_mut(sid) {
                    Some(m)
                        if m.client == client
                            && m.call_id == call_id
                            && !m.used
                            && Instant::now() < m.expires_at =>
                    {
                        m.used = true;
                        Some((m.generation.clone(), m.request_id.clone(), m.session_id.clone()))
                    }
                    _ => None,
                }
            };
            let Some((generation, _req_id, session_id)) = entry else {
                return HttpResponse::empty(404);
            };
            if !agent.is_usb_call_owner(client, call_id, &generation) {
                return HttpResponse::empty(409);
            }
            let cfg = MediaSessionConfig {
                session_id: session_id.clone(),
                offer_sdp: b.offer,
                ice_servers: Vec::new(),
                local_ip: Some(self.ipv4),
                gather_timeout: Duration::from_secs(4),
                audio_profile: agent.audio_profile,
                max_duration: Duration::from_secs(30 * 60),
            };
            match agent
                .start_media_session(
                    session_id,
                    call_id.to_string(),
                    cfg,
                    Box::new(|| {}),
                    Box::new(|_| {}),
                )
                .await
            {
                Ok(answer_sdp) => return HttpResponse::json(200, &json!({"answer": answer_sdp})),
                Err(_) => return HttpResponse::empty(503),
            }
        }

        HttpResponse::empty(404)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn sign_usb_req(token_hex: &str, method: &str, target: &str, body: &[u8], ts: i64, nonce: &str) -> HttpRequest {
        let key = hex::decode(token_hex).unwrap();
        let mut mac = HmacSha256::new_from_slice(&key).unwrap();
        mac.update(format!("{ts}\n{nonce}\n{method}\n{target}\n").as_bytes());
        mac.update(body);
        let sig = hex::encode(mac.finalize().into_bytes());
        let mut headers = HashMap::new();
        headers.insert("authorization".to_string(), format!("Bearer {token_hex}"));
        headers.insert("x-airsim-timestamp".to_string(), ts.to_string());
        headers.insert("x-airsim-nonce".to_string(), nonce.to_string());
        headers.insert("x-airsim-signature".to_string(), sig);
        HttpRequest {
            method: method.to_string(),
            target: target.to_string(),
            path: target.split('?').next().unwrap_or(target).to_string(),
            query: target.split_once('?').map(|x| x.1.to_string()).unwrap_or_default(),
            headers,
            body: body.to_vec(),
        }
    }

    #[test]
    fn usb_grant_hmac_replay_expiry_and_revoke() {
        let dir = std::env::temp_dir().join(format!("airsim-usb-test-{}", uuid_v4().unwrap()));
        let mod_id = uuid_v4().unwrap();
        let srv_id = uuid_v4().unwrap();
        let client_id = uuid_v4().unwrap();

        // Loopback must be rejected; private 192.168.225.1:8577 must succeed.
        assert!(UsbServer::configure("127.0.0.1:8577", &dir, &mod_id).is_err());
        let srv = UsbServer::configure("192.168.225.1:8577", &dir, &mod_id).unwrap();

        let exp = (OffsetDateTime::now_utc() + time::Duration::hours(24))
            .format(&time::format_description::well_known::Rfc3339)
            .unwrap();
        let auth = srv.authorize(&srv_id, &mod_id, &client_id, &exp).unwrap();
        assert_eq!(auth.api_origin, "https://192.168.225.1:8577");
        assert!(!auth.certificate_der_base64.is_empty());

        let now_s = OffsetDateTime::now_utc().unix_timestamp();
        let nonce1 = "a".repeat(64);
        let req1 = sign_usb_req(&auth.token, "GET", "/v2/modules", b"", now_s, &nonce1);
        assert_eq!(srv.authenticate(&req1), Some(client_id.clone()));

        // Replay of the exact same nonce MUST be rejected!
        assert_eq!(srv.authenticate(&req1), None);

        // Timestamp outside +/-30s window MUST be rejected!
        let nonce2 = "b".repeat(64);
        let stale = sign_usb_req(&auth.token, "GET", "/v2/modules", b"", now_s - 60, &nonce2);
        assert_eq!(srv.authenticate(&stale), None);

        // Tampered body MUST be rejected!
        let nonce3 = "c".repeat(64);
        let mut tampered = sign_usb_req(&auth.token, "POST", "/v2/modules", b"hello", now_s, &nonce3);
        tampered.body = b"world".to_vec();
        assert_eq!(srv.authenticate(&tampered), None);

        // Reload from disk preserves usb-tls.pem and usb-grants.json!
        let srv2 = UsbServer::configure("192.168.225.1:8577", &dir, &mod_id).unwrap();
        let nonce4 = "d".repeat(64);
        let req4 = sign_usb_req(&auth.token, "GET", "/v2/modules", b"", now_s, &nonce4);
        assert_eq!(srv2.authenticate(&req4), Some(client_id.clone()));

        // Revoke removes grant immediately.
        srv2.revoke(&client_id).unwrap();
        let nonce5 = "e".repeat(64);
        let req5 = sign_usb_req(&auth.token, "GET", "/v2/modules", b"", now_s, &nonce5);
        assert_eq!(srv2.authenticate(&req5), None);

        let _ = fs::remove_dir_all(&dir);
    }
}
