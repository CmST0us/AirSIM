//! Cloud WebSocket Control & Unified Real-Time WebRTC Media Bridge.
//!
//! 100% wire-compatible with ECS `service/airsim/internal/control` and `media`:
//! - HTTPS IPv4 discovery `GET /.well-known/airsim`
//! - mTLS WebSocket `wss://<device_origin>/v2/device/control` (`airsim.control.v2`)
//! - Strict sequence envelopes (`hello`, `welcome`, `heartbeat`, `snapshot`, `messages`,
//!   `command`, `receipt`, `receipt_query`, `cert_renew`, `cert_renewed`,
//!   `usb_authorize`, `usb_authorization`, `usb_revoke`, `media_start`, `media_answer`,
//!   `media_status`, `media_stop`)
//! - Unified zero-GC `MediaSessionHandle` (`str0m` + RFC 5766/8656 TURN + Opus 64k + WSOLA + ALSA)
//!   that outlives transient control WebSocket reconnects!

use crate::audio::alsa::AudioProfile;
use crate::control::{AudioSessionView, CallsView, CommandRequest, ControlStatus, Coordinator, MessagesView};
use crate::http_lite::http_get;
use crate::identity::is_valid_uuid_v4;
use crate::journal::{now_rfc3339, parse_rfc3339};
use crate::provision::{Bundle, Provisioner, SavedCloud, CLOUD_PROFILE};
use crate::rtc::{IceServer, MediaSessionConfig, MediaSessionHandle, MediaSessionStatus};
use crate::sms_pdu::SmsDiagnostics;
use crate::state::{SignalView, StateStore};
use crate::strict_json;
use crate::usb::UsbServer;
use futures_util::{SinkExt, StreamExt};
use rustls::pki_types::ServerName;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use time::OffsetDateTime;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
use tokio_rustls::TlsConnector;
use tokio_tungstenite::tungstenite::handshake::client::Request as WsRequest;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use url::Url;

const MAX_SDP: usize = 32768;
const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const CERT_RENEW_WINDOW_SECS: i64 = 7 * 24 * 3600;

#[derive(Debug, Clone)]
struct CallOwner {
    client: String,
    generation: String,
    boot: String,
    epoch: String,
}

#[derive(Debug, Clone)]
struct CallClaim {
    route: String, // "cloud" or "usb"
    client: String,
    command_id: String,
    call_id: String,
}

#[derive(Debug, Clone)]
struct CommandEntry {
    client: String,
    route: String,
}

struct ActiveBridge {
    session_id: String,
    handle: MediaSessionHandle,
}

struct OwnerState {
    owners: HashMap<String, CallOwner>,
    claim: Option<CallClaim>,
    entries: HashMap<String, CommandEntry>,
    bindings: HashMap<String, String>,
}

pub struct CloudAgent {
    pub provisioner: Arc<Provisioner>,
    pub control: Arc<Coordinator>,
    pub state: Arc<StateStore>,
    pub sms_diag: Arc<SmsDiagnostics>,
    pub usb: Option<Arc<UsbServer>>,
    pub boot_id: String,
    pub version: String,
    pub audio_profile: AudioProfile,

    owner_state: Mutex<OwnerState>,
    bridge: tokio::sync::Mutex<Option<ActiveBridge>>,
    last_stats: Mutex<MediaSessionStatus>,
    active_meta: Mutex<Option<(String, String, Arc<crate::audio::AudioEngineCounters>)>>, // (session_id, candidate, counters)
}

impl CloudAgent {
    pub fn new(
        provisioner: Arc<Provisioner>,
        control: Arc<Coordinator>,
        state: Arc<StateStore>,
        sms_diag: Arc<SmsDiagnostics>,
        usb: Option<Arc<UsbServer>>,
        boot_id: String,
        version: String,
        audio_profile: AudioProfile,
    ) -> Arc<Self> {
        let mut entries = HashMap::new();
        if let Some(ref u) = usb {
            for (cmd_id, client) in u.existing_command_clients() {
                entries.insert(
                    cmd_id,
                    CommandEntry {
                        client,
                        route: "usb".into(),
                    },
                );
            }
        }
        let zero_counters = crate::audio::AudioEngineCounters::default();
        let initial_stats = MediaSessionStatus::from_counters("", "idle", "", "", &zero_counters);
        Arc::new(Self {
            provisioner,
            control,
            state,
            sms_diag,
            usb,
            boot_id,
            version,
            audio_profile,
            owner_state: Mutex::new(OwnerState {
                owners: HashMap::new(),
                claim: None,
                entries,
                bindings: HashMap::new(),
            }),
            bridge: tokio::sync::Mutex::new(None),
            last_stats: Mutex::new(initial_stats),
            active_meta: Mutex::new(None),
        })
    }

    pub fn media_stats(&self) -> MediaSessionStatus {
        if let Some((sid, cand, counters)) = self.active_meta.lock().unwrap().clone() {
            return MediaSessionStatus::from_counters(&sid, "streaming", "", &cand, &counters);
        }
        self.last_stats.lock().unwrap().clone()
    }

    pub fn set_call_owner(
        &self,
        call_id: &str,
        client: &str,
        generation: &str,
        boot: &str,
        epoch: &str,
    ) {
        self.owner_state.lock().unwrap().owners.insert(
            call_id.to_string(),
            CallOwner {
                client: client.to_string(),
                generation: generation.to_string(),
                boot: boot.to_string(),
                epoch: epoch.to_string(),
            },
        );
    }

    pub fn is_usb_call_owner(&self, client: &str, call_id: &str, generation: &str) -> bool {
        let owner_ok = {
            let g = self.owner_state.lock().unwrap();
            let o = g.owners.get(call_id);
            let claim_ok = g
                .claim
                .as_ref()
                .is_some_and(|c| c.route == "usb" && c.client == client);
            o.is_some_and(|x| x.client == client && x.generation == generation) && claim_ok
        };
        if !owner_ok {
            return false;
        }
        let calls = self.control.calls_view();
        calls
            .calls
            .iter()
            .any(|c| c.call_id == call_id && c.state == "active")
    }

    pub fn reserve_command(&self, req: &CommandRequest, client: &str, route: &str) -> bool {
        let mut g = self.owner_state.lock().unwrap();
        if let Some(prev) = g.entries.get(&req.command_id) {
            return prev.client == client && prev.route == route;
        }
        if matches!(req.action.as_str(), "call.dial" | "call.answer") {
            if let Some(ref c) = g.claim {
                if c.route != route || c.client != client {
                    return false;
                }
            }
            g.claim = Some(CallClaim {
                route: route.to_string(),
                client: client.to_string(),
                command_id: req.command_id.clone(),
                call_id: req.args.call_id.clone(),
            });
        } else if matches!(req.action.as_str(), "call.hangup" | "call.dtmf") {
            if let Some(ref c) = g.claim {
                if c.route != route && !c.call_id.is_empty() && c.call_id == req.args.call_id {
                    // Hangup is allowed to recover stuck calls across routes only if unmanaged; keep parity.
                    if req.action == "call.dtmf" {
                        return false;
                    }
                }
            }
        }
        g.entries.insert(
            req.command_id.clone(),
            CommandEntry {
                client: client.to_string(),
                route: route.to_string(),
            },
        );
        true
    }

    pub fn reject_claim(&self, req: &CommandRequest, status_code: u16) {
        if status_code == 200 || status_code == 202 {
            return;
        }
        let mut g = self.owner_state.lock().unwrap();
        if g.claim
            .as_ref()
            .is_some_and(|c| c.command_id == req.command_id)
        {
            g.claim = None;
        }
        g.entries.remove(&req.command_id);
    }

    pub fn update_claim(&self, req: &CommandRequest, state: &str, call_id: &str) {
        let mut g = self.owner_state.lock().unwrap();
        if let Some(ref mut c) = g.claim {
            if c.command_id == req.command_id {
                if matches!(state, "failed" | "expired") {
                    g.claim = None;
                } else if !call_id.is_empty() {
                    c.call_id = call_id.to_string();
                }
            }
        }
    }

    /// Replace any running media session cleanly (joining its RT threads first so ALSA is released)
    /// and start a fresh `MediaSessionHandle`. Returns the complete SDP answer immediately!
    pub async fn start_media_session(
        self: &Arc<Self>,
        session_id: String,
        call_id: String,
        cfg: MediaSessionConfig,
        on_streaming: Box<dyn FnOnce() + Send>,
        on_closed: Box<dyn FnOnce(&'static str) + Send>,
    ) -> Result<String, &'static str> {
        // Stop and join any previous session before touching ALSA or opening a new session.
        let mut guard = self.bridge.lock().await;
        if let Some(mut old) = guard.take() {
            let _ = tokio::task::spawn_blocking(move || {
                old.handle.join();
            })
            .await;
        }

        let agent_for_close = self.clone();
        let sid_close = session_id.clone();
        let agent_for_stream = self.clone();
        let sid_stream = session_id.clone();
        let cid_stream = call_id.clone();
        let boot = self.boot_id.clone();
        let epoch = self.control.status().backend_epoch;
        let created_at = now_rfc3339();

        let started = tokio::task::spawn_blocking(move || {
            MediaSessionHandle::start(
                cfg,
                Box::new(move || {
                    agent_for_stream.control.set_active_audio(Some(AudioSessionView {
                        session_id: sid_stream,
                        call_id: cid_stream,
                        agent_boot_id: boot,
                        backend_epoch: epoch,
                        state: "streaming".into(),
                        reason: String::new(),
                        created_at,
                        closed_at: None,
                        uplink_frames: 0,
                        downlink_frames: 0,
                        uplink_sequence_gaps: 0,
                        downlink_sequence_gaps: 0,
                    }));
                    on_streaming();
                }),
                Box::new(move |reason| {
                    if let Some((sid, cand, counters)) = agent_for_close.active_meta.lock().unwrap().take() {
                        if sid == sid_close {
                            *agent_for_close.last_stats.lock().unwrap() =
                                MediaSessionStatus::from_counters(&sid, "closed", reason, &cand, &counters);
                        }
                    }
                    agent_for_close.control.set_active_audio(None);
                    on_closed(reason);
                }),
            )
        })
        .await
        .map_err(|_| "rtc_failed")??;

        let answer = started.answer_sdp.clone();
        *self.active_meta.lock().unwrap() = Some((
            session_id.clone(),
            started.candidate_label.clone(),
            started.counters.clone(),
        ));
        *guard = Some(ActiveBridge {
            session_id,
            handle: started,
        });
        Ok(answer)
    }

    pub fn stop_bridge(&self, session_id: &str) {
        if let Ok(guard) = self.bridge.try_lock() {
            if let Some(ref b) = *guard {
                if b.session_id == session_id {
                    b.handle.stop();
                }
            }
        }
    }

    pub fn stop_any_bridge(&self) {
        if let Ok(guard) = self.bridge.try_lock() {
            if let Some(ref b) = *guard {
                b.handle.stop();
            }
        }
    }

    /// Main cloud connection loop with exponential backoff and online cert renewal.
    pub async fn run(self: Arc<Self>, mut shutdown: watch::Receiver<bool>) {
        if let Some(ref u) = self.usb {
            let u_clone = u.clone();
            let ag_clone = self.clone();
            let sd_clone = shutdown.clone();
            tokio::spawn(async move {
                u_clone.serve(ag_clone, sd_clone).await;
            });
        }

        // Watch for active call ending so any running media session stops promptly when the call ends.
        {
            let ag_watch = self.clone();
            let mut sd_watch = shutdown.clone();
            tokio::spawn(async move {
                let notify = ag_watch.control.audio_notify();
                loop {
                    tokio::select! {
                        _ = sd_watch.changed() => return,
                        _ = notify.notified() => {
                            let q = ag_watch.control.audio_qualification();
                            if !q.eligible {
                                ag_watch.stop_any_bridge();
                            }
                        }
                    }
                }
            });
        }

        let delays = [250u64, 500, 1000, 2000, 4000, 5000];
        let mut attempt = 0usize;
        let changed = self.provisioner.changed();

        loop {
            if *shutdown.borrow() {
                self.stop_any_bridge();
                return;
            }
            let Some(cfg) = self.provisioner.current_config() else {
                tokio::select! {
                    _ = shutdown.changed() => return,
                    _ = changed.notified() => continue,
                }
            };

            let (code, established) = self.connect_session(&cfg, shutdown.clone()).await;
            self.provisioner.set_connection_state(false, "", code);
            eprintln!("cloud connection ended: {code}");

            if established || code == "certificate_renewed" {
                attempt = 0;
            }
            if code == "certificate_renewed" {
                continue;
            }

            let base = delays[attempt];
            let mut rnd = [0u8; 1];
            let _ = getrandom::getrandom(&mut rnd);
            let wait_ms = base + (base * (rnd[0] as u64)) / 1275;
            if attempt + 1 < delays.len() {
                attempt += 1;
            }
            eprintln!("cloud reconnect scheduled in {wait_ms}ms");
            tokio::select! {
                _ = shutdown.changed() => {
                    self.stop_any_bridge();
                    return;
                }
                _ = tokio::time::sleep(Duration::from_millis(wait_ms)) => {}
            }
        }
    }

    async fn discover(&self, cfg: &SavedCloud) -> Result<(), &'static str> {
        let tls_cfg = self
            .provisioner
            .build_tls_client_config(cfg, false)
            .map_err(|e| {
                eprintln!("cloud discovery tls_cfg error: {e}");
                "certificate_invalid"
            })?;
        let u = Url::parse(&cfg.request.api_origin).map_err(|_| "discovery_failed")?;
        let host = u.host_str().ok_or("discovery_failed")?.to_string();
        let port = u.port_or_known_default().unwrap_or(443);

        let tcp = connect_ipv4(&host, port, DISCOVERY_TIMEOUT)
            .await
            .map_err(|e| {
                eprintln!("cloud discovery tcp error: {e}");
                "discovery_failed"
            })?;
        let sni = ServerName::try_from(host.clone()).map_err(|_| "discovery_failed")?;
        let connector = TlsConnector::from(tls_cfg);
        let mut tls = tokio::time::timeout(DISCOVERY_TIMEOUT, connector.connect(sni, tcp))
            .await
            .map_err(|_| {
                eprintln!("cloud discovery tls timeout");
                "discovery_failed"
            })?
            .map_err(|e| {
                eprintln!("cloud discovery tls handshake error: {e}");
                "discovery_failed"
            })?;

        let host_hdr = if port == 443 {
            host.clone()
        } else {
            format!("{host}:{port}")
        };
        let (status, body) = tokio::time::timeout(
            DISCOVERY_TIMEOUT,
            http_get(&mut tls, &host_hdr, "/.well-known/airsim", 16384),
        )
        .await
        .map_err(|_| {
            eprintln!("cloud discovery http timeout");
            "discovery_failed"
        })?
        .map_err(|e| {
            eprintln!("cloud discovery http error: {e}");
            "discovery_failed"
        })?;

        if status != 200 {
            eprintln!("cloud discovery http status={status}");
            return Err("discovery_failed");
        }

        #[derive(Deserialize)]
        struct Discovery {
            protocol_version: i32,
            profile: String,
            server_id: String,
            api_origin: String,
            device_origin: String,
            media_origin: String,
            capabilities: Value,
        }
        let d: Discovery = strict_json::decode_exact_csv(
            &body,
            "protocol_version,profile,server_id,api_origin,device_origin,media_origin,capabilities",
            "",
        )
        .map_err(|_| "discovery_failed")?;

        if d.protocol_version != 2
            || (d.profile != CLOUD_PROFILE && d.profile != "airsim-v2-callkit")
            || d.server_id != cfg.request.server_id
            || d.api_origin != cfg.request.api_origin
            || d.device_origin != cfg.request.device_origin
            || d.media_origin != cfg.request.media_origin
        {
            return Err("discovery_failed");
        }

        #[derive(Deserialize)]
        struct Caps {
            controlled_test_client: bool,
            telephony: bool,
            messaging: bool,
            experimental_audio: bool,
            apns: bool,
            interactive_login: bool,
            #[serde(default)]
            device_pairing: bool,
            #[serde(default)]
            client_session_refresh: bool,
        }
        let cap_bytes = serde_json::to_vec(&d.capabilities).unwrap_or_default();
        let caps: Caps = strict_json::decode_exact_csv(
            &cap_bytes,
            "controlled_test_client,telephony,messaging,experimental_audio,apns,interactive_login",
            "device_pairing,client_session_refresh",
        )
        .map_err(|_| "discovery_failed")?;

        if !caps.controlled_test_client
            || !caps.telephony
            || !caps.messaging
            || !caps.experimental_audio
            || (caps.apns && d.profile != "airsim-v2-callkit")
            || caps.interactive_login
        {
            return Err("discovery_failed");
        }
        let _ = (caps.device_pairing, caps.client_session_refresh);
        Ok(())
    }

    async fn connect_session(
        self: &Arc<Self>,
        cfg: &SavedCloud,
        mut shutdown: watch::Receiver<bool>,
    ) -> (&'static str, bool) {
        let cert_expiry = match self.provisioner.validate_for_connect(cfg) {
            Ok(exp) => exp,
            Err(e) => return (e, false),
        };

        if let Err(e) = self.discover(cfg).await {
            eprintln!("cloud discovery failed: {e}");
            return ("discovery_failed", false);
        }

        let tls_cfg = match self.provisioner.build_tls_client_config(cfg, true) {
            Ok(c) => c,
            Err(_) => return ("certificate_invalid", false),
        };
        let dev_url = match Url::parse(&cfg.request.device_origin) {
            Ok(u) => u,
            Err(_) => return ("control_connect", false),
        };
        let host = match dev_url.host_str() {
            Some(h) => h.to_string(),
            None => return ("control_connect", false),
        };
        let port = dev_url.port_or_known_default().unwrap_or(443);

        let tcp = match connect_ipv4(&host, port, HANDSHAKE_TIMEOUT).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("cloud tcp connect failed: {e}");
                return ("control_connect", false);
            }
        };
        let _ = tcp.set_nodelay(true);
        let sni = match ServerName::try_from(host.clone()) {
            Ok(s) => s,
            Err(_) => return ("control_connect", false),
        };
        let connector = TlsConnector::from(tls_cfg);
        let tls = match tokio::time::timeout(HANDSHAKE_TIMEOUT, connector.connect(sni, tcp)).await {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => {
                eprintln!("cloud tls handshake failed: {e}");
                return ("control_connect", false);
            }
            Err(_) => return ("control_connect", false),
        };

        let ws_uri = format!(
            "wss://{}/v2/device/control",
            if port == 443 {
                host.clone()
            } else {
                format!("{host}:{port}")
            }
        );
        let ws_req = match WsRequest::builder()
            .uri(&ws_uri)
            .header("Host", if port == 443 { host.clone() } else { format!("{host}:{port}") })
            .header("Connection", "Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header(
                "Sec-WebSocket-Key",
                tokio_tungstenite::tungstenite::handshake::client::generate_key(),
            )
            .header("Sec-WebSocket-Protocol", "airsim.control.v2")
            .body(())
        {
            Ok(r) => r,
            Err(_) => return ("control_connect", false),
        };

        let (mut ws, resp) = match tokio::time::timeout(
            HANDSHAKE_TIMEOUT,
            tokio_tungstenite::client_async(ws_req, tls),
        )
        .await
        {
            Ok(Ok(pair)) => pair,
            Ok(Err(e)) => {
                eprintln!("cloud ws handshake failed: {e}");
                return ("control_connect", false);
            }
            Err(_) => return ("control_connect", false),
        };

        let subproto = resp
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if subproto != "airsim.control.v2" {
            return ("control_protocol", false);
        }
        let can_renew = resp
            .headers()
            .get("x-airsim-cert-renewal")
            .and_then(|v| v.to_str().ok())
            == Some("1");

        let module_id = self.provisioner.identity.module_id.clone();
        let ctl_status = self.control.status();

        // Send hello (sequence 1)
        let hello = Envelope {
            kind: "hello".into(),
            protocol_version: 2,
            module_id: module_id.clone(),
            connection_epoch: String::new(),
            sequence: 1,
            payload: json!({
                "agent_boot_id": self.boot_id,
                "backend_epoch": ctl_status.backend_epoch,
                "agent_version": self.version,
                "platform": self.provisioner.profile(),
                "usb_local": self.usb.is_some(),
                "media_codec": "opus",
            }),
        };
        let hello_txt = serde_json::to_string(&hello).unwrap();
        if tokio::time::timeout(HANDSHAKE_TIMEOUT, ws.send(WsMessage::Text(hello_txt.into())))
            .await
            .is_err()
        {
            return ("control_write", false);
        }

        // Read welcome (sequence 1)
        let welcome_msg = match tokio::time::timeout(HANDSHAKE_TIMEOUT, ws.next()).await {
            Ok(Some(Ok(WsMessage::Text(t)))) => t,
            _ => return ("control_welcome", false),
        };
        let Ok(welcome_env) = parse_envelope(welcome_msg.as_bytes(), &module_id, "", 1, true) else {
            return ("control_welcome", false);
        };
        if welcome_env.kind != "welcome" {
            return ("control_welcome", false);
        }
        #[derive(Deserialize)]
        struct WelcomePayload {
            server_id: String,
            heartbeat_seconds: i32,
        }
        let wp_bytes = serde_json::to_vec(&welcome_env.payload).unwrap_or_default();
        let Ok(wp) = strict_json::decode_exact_csv::<WelcomePayload>(
            &wp_bytes,
            "server_id,heartbeat_seconds",
            "",
        ) else {
            return ("control_welcome", false);
        };
        if wp.server_id != cfg.request.server_id || wp.heartbeat_seconds != 5 {
            return ("control_welcome", false);
        }

        let conn_epoch = welcome_env.connection_epoch;
        self.provisioner.set_connection_state(true, &conn_epoch, "");
        eprintln!("cloud connected (epoch={conn_epoch})");

        let (mut ws_sink, mut ws_stream) = ws.split();
        let (out_tx, mut out_rx) = mpsc::channel::<(String, Value)>(64);

        // Writer task
        let w_mod = module_id.clone();
        let w_epoch = conn_epoch.clone();
        let writer_task = tokio::spawn(async move {
            let mut seq = 1u64;
            while let Some((kind, payload)) = out_rx.recv().await {
                seq += 1;
                let env = Envelope {
                    kind: kind.clone(),
                    protocol_version: 2,
                    module_id: w_mod.clone(),
                    connection_epoch: w_epoch.clone(),
                    sequence: seq,
                    payload,
                };
                let Ok(txt) = serde_json::to_string(&env) else {
                    break;
                };
                let limit = if kind == "messages" { 65536 } else { 131072 };
                if txt.len() > limit {
                    break;
                }
                if tokio::time::timeout(Duration::from_secs(3), ws_sink.send(WsMessage::Text(txt.into())))
                    .await
                    .map_err(|_| ())
                    .and_then(|r| r.map_err(|_| ()))
                    .is_err()
                {
                    break;
                }
            }
        });

        let mut last_sync = SyncedState::default();
        let mut pending_receipts: HashMap<String, PendingReceipt> = HashMap::new();
        let mut rx_seq = 1u64;
        let mut renewed = false;

        // Initial snapshot sync
        if !self.sync_state(&out_tx, &mut last_sync) {
            writer_task.abort();
            return ("snapshot_failed", true);
        }

        // Check online certificate renewal on connect if within 7 days of expiry
        if can_renew {
            let rem = (cert_expiry - OffsetDateTime::now_utc()).whole_seconds();
            if rem <= CERT_RENEW_WINDOW_SECS {
                if let Some((req_id, nonce, csr_pem)) = self.provisioner.renewal_request() {
                    let _ = out_tx.try_send((
                        "cert_renew".into(),
                        json!({"request_id": req_id, "nonce": nonce, "csr_pem": csr_pem}),
                    ));
                }
            }
        }

        let mut sync_tick = tokio::time::interval(Duration::from_secs(1));
        let mut heart_tick = tokio::time::interval(Duration::from_secs(5));
        let mut receipt_tick = tokio::time::interval(Duration::from_millis(250));
        let mut last_rx = Instant::now();

        let exit_reason: &'static str = loop {
            if OffsetDateTime::now_utc() >= cert_expiry {
                break "certificate_expired";
            }
            if last_rx.elapsed() > Duration::from_secs(15) {
                break "control_disconnected";
            }
            if writer_task.is_finished() {
                break "control_write";
            }

            tokio::select! {
                _ = shutdown.changed() => break "stopped",
                msg = ws_stream.next() => {
                    match msg {
                        Some(Ok(WsMessage::Text(txt))) => {
                            last_rx = Instant::now();
                            rx_seq += 1;
                            let Ok(env) = parse_envelope(txt.as_bytes(), &module_id, &conn_epoch, rx_seq, false) else {
                                break "control_protocol";
                            };
                            match self.handle_frame(env, &out_tx, &mut pending_receipts).await {
                                HandleOutcome::Continue => {}
                                HandleOutcome::Renewed => {
                                    renewed = true;
                                    break "certificate_renewed";
                                }
                                HandleOutcome::ProtocolError => break "control_protocol",
                            }
                        }
                        Some(Ok(WsMessage::Ping(_))) | Some(Ok(WsMessage::Pong(_))) => {
                            last_rx = Instant::now();
                        }
                        _ => break "control_disconnected",
                    }
                }
                _ = sync_tick.tick() => {
                    if !self.sync_state(&out_tx, &mut last_sync) {
                        break "snapshot_failed";
                    }
                }
                _ = receipt_tick.tick(), if !pending_receipts.is_empty() => {
                    let ids: Vec<String> = pending_receipts.keys().cloned().collect();
                    for id in ids {
                        if let Some(mut p) = pending_receipts.remove(&id) {
                            let keep = self.emit_receipt(&mut p, &out_tx);
                            if keep {
                                pending_receipts.insert(id, p);
                            }
                        }
                    }
                }
                _ = heart_tick.tick() => {
                    if out_tx.try_send(("heartbeat".into(), json!({}))).is_err() {
                        break "control_queue";
                    }
                }
            }
        };

        drop(out_tx);
        writer_task.abort();
        if renewed {
            ("certificate_renewed", true)
        } else {
            (exit_reason, true)
        }
    }

    fn sync_state(&self, out_tx: &mpsc::Sender<(String, Value)>, last: &mut SyncedState) -> bool {
        let st = self.control.status();
        let calls = self.control.calls_view();
        let sig = self.state.signal();
        let audio = self.control.audio_view();

        let active_call = calls.calls.iter().any(|c| c.state != "disconnected");
        let interval = if active_call {
            Duration::from_secs(1)
        } else {
            Duration::from_secs(5)
        };

        let base_payload = json!({
            "agent_boot_id": st.agent_boot_id,
            "backend_epoch": st.backend_epoch,
            "observed_at": "",
            "control": st,
            "calls": calls,
            "audio": audio,
            "signal": sig,
        });
        let base_str = serde_json::to_string(&base_payload).unwrap_or_default();

        if base_str != last.snapshot_key || last.last_sent.elapsed() >= interval {
            let mut full = base_payload;
            full["observed_at"] = Value::String(now_rfc3339());
            if out_tx.try_send(("snapshot".into(), full)).is_err() {
                return false;
            }
            last.snapshot_key = base_str;
            last.last_sent = Instant::now();
        }

        // Prune expired call owners when calls disconnect or epoch changes.
        {
            let mut g = self.owner_state.lock().unwrap();
            g.owners.retain(|cid, o| {
                calls.calls.iter().any(|c| {
                    c.call_id == *cid
                        && c.state != "disconnected"
                        && o.boot == st.agent_boot_id
                        && o.epoch == st.backend_epoch
                })
            });
            if let Some(ref c) = g.claim {
                if !c.call_id.is_empty()
                    && !calls
                        .calls
                        .iter()
                        .any(|x| x.call_id == c.call_id && x.state != "disconnected")
                {
                    g.claim = None;
                }
            }
        }

        // Sync messages (batched <= 32 items and <= 60 KB per frame)
        let msgs = self.control.messages_view(true);
        if msgs.agent_boot_id == st.agent_boot_id
            && msgs.backend_epoch == st.backend_epoch
            && last.messages.as_ref() != Some(&msgs)
        {
            let mut batch = Vec::new();
            for m in &msgs.messages {
                let mut cand = batch.clone();
                cand.push(m.clone());
                let size = serde_json::to_vec(&cand).map(|v| v.len()).unwrap_or(99999);
                if cand.len() > 32 || size > 60000 {
                    if !batch.is_empty() {
                        let frame = json!({
                            "agent_boot_id": msgs.agent_boot_id,
                            "backend_epoch": msgs.backend_epoch,
                            "observed_at": now_rfc3339(),
                            "inbox_gap": msgs.inbox_gap,
                            "inbox_dropped": msgs.inbox_dropped,
                            "messages": batch,
                        });
                        if out_tx.try_send(("messages".into(), frame)).is_err() {
                            return false;
                        }
                        batch.clear();
                    }
                    batch.push(m.clone());
                } else {
                    batch = cand;
                }
            }
            let frame = json!({
                "agent_boot_id": msgs.agent_boot_id,
                "backend_epoch": msgs.backend_epoch,
                "observed_at": now_rfc3339(),
                "inbox_gap": msgs.inbox_gap,
                "inbox_dropped": msgs.inbox_dropped,
                "messages": batch,
            });
            if out_tx.try_send(("messages".into(), frame)).is_err() {
                return false;
            }
            last.messages = Some(msgs);
        }
        true
    }

    fn emit_receipt(
        &self,
        p: &mut PendingReceipt,
        out_tx: &mpsc::Sender<(String, Value)>,
    ) -> bool {
        let rcpt = self.control.command_receipt(&p.request.command_id);
        let code = if rcpt.is_some() { 200u16 } else { 404u16 };
        let val = serde_json::to_value(&rcpt).unwrap_or(Value::Null);
        let key = serde_json::to_string(&val).unwrap_or_default();
        if key != p.last_sent_json {
            let _ = out_tx.try_send((
                "receipt".into(),
                json!({
                    "command_id": p.request.command_id,
                    "status_code": code,
                    "receipt": val,
                }),
            ));
            p.last_sent_json = key;
        }
        let Some(r) = rcpt else {
            return false;
        };
        if p.authorized
            && matches!(r.state.as_str(), "accepted" | "observed")
            && is_valid_uuid_v4(&r.call_id)
            && matches!(p.request.action.as_str(), "call.dial" | "call.answer")
        {
            self.set_call_owner(
                &r.call_id,
                &p.client,
                &p.generation,
                &p.request.agent_boot_id,
                &p.request.backend_epoch,
            );
        }
        self.update_claim(&p.request, &r.state, &r.call_id);
        let mut keep = matches!(r.state.as_str(), "prepared" | "dispatched");
        if r.state == "accepted" && matches!(p.request.action.as_str(), "call.answer" | "call.hangup") {
            let until = *p
                .accepted_until
                .get_or_insert_with(|| Instant::now() + Duration::from_secs(11));
            keep = Instant::now() < until;
        }
        keep
    }

    async fn handle_frame(
        self: &Arc<Self>,
        env: Envelope,
        out_tx: &mpsc::Sender<(String, Value)>,
        pending: &mut HashMap<String, PendingReceipt>,
    ) -> HandleOutcome {
        let pbytes = serde_json::to_vec(&env.payload).unwrap_or_default();
        match env.kind.as_str() {
            "heartbeat" => {
                if strict_json::parse_object(&pbytes, &[], &[]).is_err() {
                    return HandleOutcome::ProtocolError;
                }
                HandleOutcome::Continue
            }
            "cert_renewed" => {
                let Ok(bundle) = strict_json::decode_exact_csv::<Bundle>(
                    &pbytes,
                    "request_id,server_id,module_id,certificate_pem,receipt_base64",
                    "",
                ) else {
                    return HandleOutcome::ProtocolError;
                };
                match self.provisioner.renew(bundle) {
                    Ok(exp) => {
                        eprintln!("cloud certificate renewed (new expiry {exp})");
                        HandleOutcome::Renewed
                    }
                    Err(e) => {
                        eprintln!("cloud certificate renewal rejected: {e}");
                        HandleOutcome::Continue
                    }
                }
            }
            "usb_revoke" => {
                #[derive(Deserialize)]
                struct Revoke {
                    client_installation_id: String,
                }
                let Ok(v) =
                    strict_json::decode_exact_csv::<Revoke>(&pbytes, "client_installation_id", "")
                else {
                    return HandleOutcome::ProtocolError;
                };
                if !is_valid_uuid_v4(&v.client_installation_id) {
                    return HandleOutcome::ProtocolError;
                }
                if let Some(ref u) = self.usb {
                    let _ = u.revoke(&v.client_installation_id);
                }
                HandleOutcome::Continue
            }
            "usb_authorize" => {
                #[derive(Deserialize)]
                struct AuthReq {
                    request_id: String,
                    client_installation_id: String,
                    expires_at: String,
                }
                let Ok(v) = strict_json::decode_exact_csv::<AuthReq>(
                    &pbytes,
                    "request_id,client_installation_id,expires_at",
                    "",
                ) else {
                    return HandleOutcome::ProtocolError;
                };
                if !is_valid_uuid_v4(&v.request_id) || !is_valid_uuid_v4(&v.client_installation_id) {
                    return HandleOutcome::ProtocolError;
                }
                let server_id = self.provisioner.view().server_id;
                let module_id = self.provisioner.identity.module_id.clone();
                let (code, auth_val) = if let Some(ref u) = self.usb {
                    match u.authorize(&server_id, &module_id, &v.client_installation_id, &v.expires_at) {
                        Ok(grant) => (200u16, serde_json::to_value(grant).unwrap_or(Value::Null)),
                        Err(_) => (503u16, Value::Null),
                    }
                } else {
                    (503u16, Value::Null)
                };
                let _ = out_tx.try_send((
                    "usb_authorization".into(),
                    json!({
                        "request_id": v.request_id,
                        "status_code": code,
                        "authorization": auth_val,
                    }),
                ));
                HandleOutcome::Continue
            }
            "command" => {
                #[derive(Deserialize)]
                struct CmdEnv {
                    client_installation_id: String,
                    generation: String,
                    command: Value,
                }
                let Ok(v) = strict_json::decode_exact_csv::<CmdEnv>(
                    &pbytes,
                    "client_installation_id,generation,command",
                    "",
                ) else {
                    return HandleOutcome::ProtocolError;
                };
                if !is_valid_uuid_v4(&v.client_installation_id) || !is_valid_uuid_v4(&v.generation) {
                    return HandleOutcome::ProtocolError;
                }
                let cmd_bytes = serde_json::to_vec(&v.command).unwrap_or_default();
                let Ok(req) = CommandRequest::parse(&cmd_bytes) else {
                    return HandleOutcome::ProtocolError;
                };
                if pending.len() >= 64 {
                    let _ = out_tx.try_send((
                        "receipt".into(),
                        json!({"command_id": req.command_id, "status_code": 429, "receipt": Value::Null}),
                    ));
                    return HandleOutcome::Continue;
                }
                let mut h = Sha256::new();
                h.update(req.canonical_bytes());
                h.update(v.client_installation_id.as_bytes());
                h.update(v.generation.as_bytes());
                let binding = hex::encode(h.finalize());
                let known = {
                    let g = self.owner_state.lock().unwrap();
                    if let Some(old) = g.bindings.get(&req.command_id) {
                        if *old != binding {
                            let _ = out_tx.try_send((
                                "receipt".into(),
                                json!({"command_id": req.command_id, "status_code": 409, "receipt": Value::Null}),
                            ));
                            return HandleOutcome::Continue;
                        }
                        true
                    } else {
                        false
                    }
                };
                if !self.reserve_command(&req, &v.client_installation_id, "cloud") {
                    let _ = out_tx.try_send((
                        "receipt".into(),
                        json!({"command_id": req.command_id, "status_code": 409, "receipt": Value::Null}),
                    ));
                    return HandleOutcome::Continue;
                }
                let (rcpt, code) = self.control.submit(req.clone());
                self.reject_claim(&req, code);
                let authorized = known || code == 202;
                if code == 202 {
                    self.owner_state
                        .lock()
                        .unwrap()
                        .bindings
                        .insert(req.command_id.clone(), binding);
                }
                let mut pr = PendingReceipt {
                    request: req.clone(),
                    client: v.client_installation_id,
                    generation: v.generation,
                    last_sent_json: String::new(),
                    authorized,
                    accepted_until: None,
                };
                // Send immediate receipt with actual submit HTTP status code (202/200/409/etc)
                let val = serde_json::to_value(&rcpt).unwrap_or(Value::Null);
                pr.last_sent_json = serde_json::to_string(&val).unwrap_or_default();
                let _ = out_tx.try_send((
                    "receipt".into(),
                    json!({"command_id": req.command_id, "status_code": code, "receipt": val}),
                ));
                if code == 202 || code == 200 {
                    if let Some(r) = rcpt {
                        if matches!(r.state.as_str(), "prepared" | "dispatched")
                            || (r.state == "accepted"
                                && matches!(req.action.as_str(), "call.answer" | "call.hangup"))
                        {
                            pending.insert(req.command_id.clone(), pr);
                        }
                    }
                }
                HandleOutcome::Continue
            }
            "receipt_query" => {
                #[derive(Deserialize)]
                struct Query {
                    command_id: String,
                }
                let Ok(v) = strict_json::decode_exact_csv::<Query>(&pbytes, "command_id", "") else {
                    return HandleOutcome::ProtocolError;
                };
                if !is_valid_uuid_v4(&v.command_id) {
                    return HandleOutcome::ProtocolError;
                }
                if let Some(mut p) = pending.remove(&v.command_id) {
                    p.last_sent_json.clear();
                    if self.emit_receipt(&mut p, out_tx) {
                        pending.insert(v.command_id, p);
                    }
                } else {
                    let rcpt = self.control.command_receipt(&v.command_id);
                    let code = if rcpt.is_some() { 200 } else { 404 };
                    let _ = out_tx.try_send((
                        "receipt".into(),
                        json!({"command_id": v.command_id, "status_code": code, "receipt": rcpt}),
                    ));
                }
                HandleOutcome::Continue
            }
            "media_start" => {
                self.handle_media_start(&pbytes, out_tx).await
            }
            "media_stop" => {
                #[derive(Deserialize)]
                struct Stop {
                    session_id: String,
                    reason: String,
                }
                let Ok(v) =
                    strict_json::decode_exact_csv::<Stop>(&pbytes, "session_id,reason", "")
                else {
                    return HandleOutcome::ProtocolError;
                };
                if !is_valid_uuid_v4(&v.session_id) || v.reason.len() > 128 {
                    return HandleOutcome::ProtocolError;
                }
                self.stop_bridge(&v.session_id);
                HandleOutcome::Continue
            }
            _ => HandleOutcome::ProtocolError,
        }
    }

    async fn handle_media_start(
        self: &Arc<Self>,
        pbytes: &[u8],
        out_tx: &mpsc::Sender<(String, Value)>,
    ) -> HandleOutcome {
        #[derive(Deserialize)]
        struct MediaStart {
            request_id: String,
            session_id: String,
            call_id: String,
            agent_boot_id: String,
            backend_epoch: String,
            client_installation_id: String,
            generation: String,
            expires_at: String,
            offer: String,
            ice_servers: Vec<Value>,
        }
        let Ok(r) = strict_json::decode_exact_csv::<MediaStart>(
            pbytes,
            "request_id,session_id,call_id,agent_boot_id,backend_epoch,client_installation_id,generation,expires_at,offer,ice_servers",
            "",
        ) else {
            return HandleOutcome::ProtocolError;
        };
        for id in [
            &r.request_id,
            &r.session_id,
            &r.call_id,
            &r.agent_boot_id,
            &r.backend_epoch,
            &r.client_installation_id,
            &r.generation,
        ] {
            if !is_valid_uuid_v4(id) {
                return HandleOutcome::ProtocolError;
            }
        }
        if r.offer.len() > MAX_SDP || !r.offer.starts_with("v=0\r\n") {
            return HandleOutcome::ProtocolError;
        }
        let Some(exp) = parse_rfc3339(&r.expires_at) else {
            return HandleOutcome::ProtocolError;
        };
        let rem = exp - OffsetDateTime::now_utc();
        if rem.is_negative() || rem.is_zero() || rem > time::Duration::seconds(20) {
            return HandleOutcome::ProtocolError;
        }
        if r.ice_servers.is_empty() || r.ice_servers.len() > 4 {
            return HandleOutcome::ProtocolError;
        }
        let mut servers = Vec::with_capacity(r.ice_servers.len());
        for raw_s in &r.ice_servers {
            let sb = serde_json::to_vec(raw_s).unwrap_or_default();
            let Ok(s) =
                strict_json::decode_exact_csv::<IceServer>(&sb, "urls,username,credential", "")
            else {
                return HandleOutcome::ProtocolError;
            };
            if s.urls.is_empty()
                || s.urls.len() > 4
                || s.username.is_empty()
                || s.credential.is_empty()
                || !s.urls.iter().all(|u| u.starts_with("turn:") && u.len() <= 256)
            {
                return HandleOutcome::ProtocolError;
            }
            servers.push(s);
        }

        // Verify ownership
        let owner_ok = {
            let g = self.owner_state.lock().unwrap();
            let usb_owned = g.claim.as_ref().is_some_and(|c| c.route == "usb");
            !usb_owned
                && g.owners.get(&r.call_id).is_some_and(|o| {
                    o.client == r.client_installation_id
                        && o.generation == r.generation
                        && o.boot == r.agent_boot_id
                        && o.epoch == r.backend_epoch
                })
        };
        if !owner_ok {
            let _ = out_tx.try_send((
                "media_status".into(),
                json!({"session_id": r.session_id, "state": "closed", "reason": "media_owner"}),
            ));
            return HandleOutcome::Continue;
        }

        let _ = out_tx.try_send((
            "media_status".into(),
            json!({"session_id": r.session_id, "state": "starting", "reason": ""}),
        ));

        let ag = self.clone();
        let tx_clone = out_tx.clone();
        let sid = r.session_id.clone();
        let cid = r.call_id.clone();
        tokio::spawn(async move {
            let tx_stream = tx_clone.clone();
            let sid_stream = sid.clone();
            let tx_close = tx_clone.clone();
            let sid_close = sid.clone();

            let cfg = MediaSessionConfig {
                session_id: sid.clone(),
                offer_sdp: r.offer,
                ice_servers: servers,
                local_ip: None,
                gather_timeout: Duration::from_secs(8),
                audio_profile: ag.audio_profile,
                max_duration: Duration::from_secs(30 * 60),
            };
            match ag
                .start_media_session(
                    sid.clone(),
                    cid,
                    cfg,
                    Box::new(move || {
                        let _ = tx_stream.try_send((
                            "media_status".into(),
                            json!({"session_id": sid_stream, "state": "streaming", "reason": ""}),
                        ));
                    }),
                    Box::new(move |reason| {
                        let _ = tx_close.try_send((
                            "media_status".into(),
                            json!({"session_id": sid_close, "state": "closed", "reason": reason}),
                        ));
                    }),
                )
                .await
            {
                Ok(answer) => {
                    let _ = tx_clone.try_send((
                        "media_answer".into(),
                        json!({"session_id": sid, "answer": answer}),
                    ));
                }
                Err(err_reason) => {
                    let _ = tx_clone.try_send((
                        "media_status".into(),
                        json!({"session_id": sid, "state": "closed", "reason": err_reason}),
                    ));
                }
            }
        });

        HandleOutcome::Continue
    }
}

enum HandleOutcome {
    Continue,
    Renewed,
    ProtocolError,
}

#[derive(Debug, Serialize, Deserialize)]
struct Envelope {
    #[serde(rename = "type")]
    kind: String,
    protocol_version: i32,
    module_id: String,
    connection_epoch: String,
    sequence: u64,
    payload: Value,
}

fn parse_envelope(
    bytes: &[u8],
    module_id: &str,
    expected_epoch: &str,
    expected_seq: u64,
    is_welcome: bool,
) -> Result<Envelope, ()> {
    let env: Envelope = strict_json::decode_exact_csv(
        bytes,
        "type,protocol_version,module_id,connection_epoch,sequence,payload",
        "",
    )
    .map_err(|_| ())?;
    if env.protocol_version != 2
        || env.module_id != module_id
        || env.sequence != expected_seq
        || expected_seq == 0
    {
        return Err(());
    }
    if is_welcome {
        if !is_valid_uuid_v4(&env.connection_epoch) {
            return Err(());
        }
    } else if env.connection_epoch != expected_epoch {
        return Err(());
    }
    Ok(env)
}

struct PendingReceipt {
    request: CommandRequest,
    client: String,
    generation: String,
    last_sent_json: String,
    authorized: bool,
    accepted_until: Option<Instant>,
}

struct SyncedState {
    snapshot_key: String,
    last_sent: Instant,
    messages: Option<MessagesView>,
}

impl Default for SyncedState {
    fn default() -> Self {
        Self {
            snapshot_key: String::new(),
            last_sent: Instant::now() - Duration::from_secs(60),
            messages: None,
        }
    }
}

async fn connect_ipv4(host: &str, port: u16, timeout: Duration) -> std::io::Result<TcpStream> {
    let addrs: Vec<SocketAddr> = tokio::time::timeout(timeout, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::TimedOut, "dns_timeout"))??
        .filter(|a| a.is_ipv4())
        .collect();
    if addrs.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AddrNotAvailable,
            "no_ipv4_addr",
        ));
    }
    let mut last_err = None;
    for addr in addrs {
        match tokio::time::timeout(timeout, TcpStream::connect(addr)).await {
            Ok(Ok(s)) => return Ok(s),
            Ok(Err(e)) => last_err = Some(e),
            Err(_) => {
                last_err = Some(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "connect_timeout",
                ))
            }
        }
    }
    Err(last_err.unwrap_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "connect_failed")))
}

// Keep unused imports silent cleanly if compiler flags them
#[allow(dead_code)]
fn _touch_types(_: ControlStatus, _: CallsView, _: SignalView) {}
