//! Cloud provisioning, certificate verification, 90-day renewal, pairing proof API,
//! pure-Rust Ed25519 PKCS#10 CSR generation, and mTLS `rustls::ClientConfig` builder.
//!
//! 100% file-format and wire-compatible with Go `internal/cloud/provision.go` & `pairing.go`:
//! - Persists `config/cloud.json` (0600, schema_version 1) and `config/cloud.json.pending`.
//! - Supports 1980 cold-boot RTC structural cert validation at `NotBefore` on startup.
//! - Loads PEM roots from `server_ca_pem`, `SSL_CERT_DIR` / `SSL_CERT_FILE`, and `webpki-roots`.

use crate::http_lite::{HttpRequest, HttpResponse};
use crate::identity::{is_valid_uuid_v4, uuid_v4, Identity};
use crate::journal::parse_rfc3339;
use crate::strict_json;
use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::{ClientConfig, RootCertStore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use ::time::format_description::well_known::Rfc3339;
use ::time::OffsetDateTime;
use url::Url;
use x509_parser::certificate::X509Certificate;
use x509_parser::extensions::GeneralName;
use x509_parser::prelude::FromDer;

pub const CLOUD_PROFILE: &str = "airsim-v2-r4.1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prepare {
    pub request_id: String,
    pub server_id: String,
    pub api_origin: String,
    pub device_origin: String,
    pub media_origin: String,
    pub device_ca_pem: String,
    pub server_ca_pem: String,
    pub nonce: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prepared {
    pub request_id: String,
    pub module_id: String,
    pub public_key_base64: String,
    pub csr_pem: String,
    pub proof_base64: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bundle {
    pub request_id: String,
    pub server_id: String,
    pub module_id: String,
    pub certificate_pem: String,
    pub receipt_base64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SavedCloud {
    pub schema_version: i32,
    pub request: Prepare,
    pub response: Prepared,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activation: Option<Bundle>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudStatus {
    pub configured: bool,
    pub connected: bool,
    pub server_id: String,
    pub module_id: String,
    pub connection_epoch: String,
    pub last_connected_at: Option<String>,
    pub last_error: String,
    pub certificate_expires_at: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
struct PairingStatus {
    module_id: String,
    public_key_base64: String,
    profile: String,
    configured: bool,
    server_id: String,
    api_origin: String,
    media_origin: String,
    connected: bool,
    certificate_expires_at: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct PairingRequest {
    request_id: String,
    server_id: String,
    module_id: String,
    nonce: String,
    expires_at: String,
    poll_token_hash: String,
}

#[derive(Debug, Clone, Serialize)]
struct PairingProof {
    request_id: String,
    module_id: String,
    public_key_base64: String,
    proof_base64: String,
}

pub fn is_valid_https_origin(s: &str) -> bool {
    let Ok(u) = Url::parse(s) else {
        return false;
    };
    u.scheme() == "https"
        && u.host_str().is_some()
        && u.username().is_empty()
        && u.password().is_none()
        && (u.path().is_empty() || u.path() == "/")
        && u.query().is_none()
        && u.fragment().is_none()
        && !s.contains(['\r', '\n'])
        && !s.ends_with('/')
}

pub fn is_hex32(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn sha256_hex(b: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(b);
    hex::encode(h.finalize())
}

fn decode_strict_b64(s: &str) -> Option<Vec<u8>> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = b64.decode(s.as_bytes()).ok()?;
    if b64.encode(&bytes) == s {
        Some(bytes)
    } else {
        None
    }
}

fn parse_single_cert_pem(pem_str: &str) -> Option<Vec<u8>> {
    let parsed = pem::parse(pem_str.trim()).ok()?;
    if parsed.tag() != "CERTIFICATE" {
        return None;
    }
    Some(parsed.into_contents())
}

fn proof_bytes(r: &Prepare, module_id: &str, csr_der: &[u8]) -> Vec<u8> {
    format!(
        "airsim-v2-r4-provision\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
        r.request_id,
        r.server_id,
        module_id,
        r.api_origin,
        r.device_origin,
        r.media_origin,
        r.nonce,
        r.expires_at,
        sha256_hex(csr_der)
    )
    .into_bytes()
}

fn receipt_bytes(r: &Prepare, b: &Bundle, cert_der: &[u8]) -> Vec<u8> {
    format!(
        "airsim-v2-r4-commit\n{}\n{}\n{}\n{}\n{}\n",
        b.request_id,
        b.server_id,
        b.module_id,
        sha256_hex(cert_der),
        r.nonce
    )
    .into_bytes()
}

fn pairing_bytes(r: &PairingRequest) -> Vec<u8> {
    format!(
        "airsim-v2-pairing\n{}\n{}\n{}\n{}\n{}\n{}\n",
        r.request_id, r.server_id, r.module_id, r.nonce, r.expires_at, r.poll_token_hash
    )
    .into_bytes()
}

// --- Pure-Rust minimal ASN.1 DER encoder for Ed25519 PKCS#10 CSR ---
// Produces a standard RFC 2986 CertificationRequest with:
// - version v1 (0)
// - subject: CN = <module_id>
// - subjectPKInfo: OID 1.3.101.112 (Ed25519) + 32-byte public key BIT STRING
// - attributes [0]: extensionRequest (1.2.840.113549.1.9.14) -> SAN (2.5.29.17) -> URI [6]
// - signatureAlgorithm: OID 1.3.101.112 (Ed25519)
// - signature: Ed25519 signature over CertificationRequestInfo DER.
fn der_tlv(tag: u8, value: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(value.len() + 6);
    out.push(tag);
    let len = value.len();
    if len < 128 {
        out.push(len as u8);
    } else if len < 256 {
        out.push(0x81);
        out.push(len as u8);
    } else {
        out.push(0x82);
        out.push((len >> 8) as u8);
        out.push((len & 0xff) as u8);
    }
    out.extend_from_slice(value);
    out
}

fn der_seq(parts: &[Vec<u8>]) -> Vec<u8> {
    let mut body = Vec::new();
    for p in parts {
        body.extend_from_slice(p);
    }
    der_tlv(0x30, &body)
}

fn der_set(parts: &[Vec<u8>]) -> Vec<u8> {
    let mut body = Vec::new();
    for p in parts {
        body.extend_from_slice(p);
    }
    der_tlv(0x31, &body)
}

fn der_bit_string(bytes: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(bytes.len() + 1);
    body.push(0x00); // 0 unused bits
    body.extend_from_slice(bytes);
    der_tlv(0x03, &body)
}

pub fn build_ed25519_csr_der(id: &Identity, san_uri: &str) -> Vec<u8> {
    let version = vec![0x02, 0x01, 0x00]; // INTEGER 0
    // Subject: SEQUENCE { SET { SEQUENCE { OID 2.5.4.3 (CN), UTF8String module_id } } }
    let oid_cn = der_tlv(0x06, &[0x55, 0x04, 0x03]);
    let cn_val = der_tlv(0x0C, id.module_id.as_bytes());
    let subject = der_seq(&[der_set(&[der_seq(&[oid_cn, cn_val])])]);

    // SubjectPublicKeyInfo: SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING pubkey }
    let oid_ed25519 = der_tlv(0x06, &[0x2B, 0x65, 0x70]);
    let alg_ed25519 = der_seq(&[oid_ed25519]);
    let spki = der_seq(&[alg_ed25519.clone(), der_bit_string(&id.public_key_bytes())]);

    // ExtensionRequest attribute -> SAN extension containing single URI [6]
    let san_uri_tlv = der_tlv(0x86, san_uri.as_bytes()); // Context-specific primitive tag 6 (uniformResourceIdentifier)
    let san_val = der_tlv(0x04, &der_seq(&[san_uri_tlv])); // OCTET STRING wrapping GeneralNames
    let oid_san = der_tlv(0x06, &[0x55, 0x1D, 0x11]); // 2.5.29.17
    let ext_san = der_seq(&[oid_san, san_val]);
    let exts = der_seq(&[ext_san]);
    let oid_ext_req = der_tlv(0x06, &[0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x0E]);
    let attr = der_seq(&[oid_ext_req, der_set(&[exts])]);
    let attrs = der_tlv(0xA0, &attr);

    let cri = der_seq(&[version, subject, spki, attrs]);
    let sig = id.sign(&cri);
    der_seq(&[cri, alg_ed25519, der_bit_string(&sig.to_bytes())])
}

pub fn pem_encode(tag: &str, der: &[u8]) -> String {
    pem::encode(&pem::Pem::new(tag.to_string(), der.to_vec())).replace("\r\n", "\n")
}

/// Cryptographically validate a saved cloud configuration against the module's Ed25519 identity
/// and pinned DeviceCA. Returns the leaf certificate's `NotAfter` UTC timestamp.
fn validate_saved(
    id: &Identity,
    s: &SavedCloud,
    activated: bool,
    check_wall_clock: bool,
) -> Result<Option<OffsetDateTime>, &'static str> {
    if s.schema_version != 1
        || !is_valid_uuid_v4(&s.request.request_id)
        || !is_valid_uuid_v4(&s.request.server_id)
        || !is_valid_https_origin(&s.request.api_origin)
        || !is_valid_https_origin(&s.request.device_origin)
        || !is_valid_https_origin(&s.request.media_origin)
        || !is_hex32(&s.request.nonce)
        || parse_rfc3339(&s.request.expires_at).is_none()
        || s.response.request_id != s.request.request_id
        || s.response.module_id != id.module_id
    {
        return Err("cloud_config");
    }

    let pub_bytes = decode_strict_b64(&s.response.public_key_base64).ok_or("cloud_config")?;
    if pub_bytes != id.public_key_bytes() {
        return Err("cloud_config");
    }

    let csr_pem = pem::parse(s.response.csr_pem.trim()).map_err(|_| "cloud_config")?;
    if csr_pem.tag() != "CERTIFICATE REQUEST" {
        return Err("cloud_config");
    }
    let proof = decode_strict_b64(&s.response.proof_base64).ok_or("cloud_config")?;
    let sig = Signature::from_slice(&proof).map_err(|_| "cloud_config")?;
    id.verifying_key()
        .verify(&proof_bytes(&s.request, &id.module_id, csr_pem.contents()), &sig)
        .map_err(|_| "cloud_config")?;

    // Parse & check DeviceCA (must be CA with Ed25519 public key)
    let ca_der = parse_single_cert_pem(&s.request.device_ca_pem).ok_or("cloud_config")?;
    let (_, ca_cert) = X509Certificate::from_der(&ca_der).map_err(|_| "cloud_config")?;
    if !ca_cert.is_ca() {
        return Err("cloud_config");
    }
    let ca_pub_bytes: [u8; 32] = ca_cert
        .public_key()
        .subject_public_key
        .data
        .as_ref()
        .try_into()
        .map_err(|_| "cloud_config")?;
    let ca_vk = VerifyingKey::from_bytes(&ca_pub_bytes).map_err(|_| "cloud_config")?;

    if !activated {
        if s.activation.is_some() {
            return Err("cloud_config");
        }
        return Ok(None);
    }

    let b = s.activation.as_ref().ok_or("cloud_config")?;
    if b.request_id != s.request.request_id
        || b.server_id != s.request.server_id
        || b.module_id != id.module_id
    {
        return Err("cloud_config");
    }

    let leaf_der = parse_single_cert_pem(&b.certificate_pem).ok_or("cloud_config")?;
    let (_, leaf) = X509Certificate::from_der(&leaf_der).map_err(|_| "cloud_config")?;

    // Verify leaf signature by DeviceCA Ed25519 key
    let leaf_sig = Signature::from_slice(leaf.signature_value.data.as_ref())
        .map_err(|_| "cloud_config")?;
    ca_vk
        .verify(leaf.tbs_certificate.as_ref(), &leaf_sig)
        .map_err(|_| "cloud_config")?;

    // Verify leaf public key == module public key
    if leaf.public_key().subject_public_key.data.as_ref() != id.public_key_bytes() {
        return Err("cloud_config");
    }
    if leaf.is_ca() {
        return Err("cloud_config");
    }

    // Verify exact SAN URI == urn:airsim:<server_id>:module:<module_id>
    let expected_uri = format!("urn:airsim:{}:module:{}", s.request.server_id, id.module_id);
    let san = leaf
        .subject_alternative_name()
        .map_err(|_| "cloud_config")?
        .ok_or("cloud_config")?;
    if san.value.general_names.len() != 1 {
        return Err("cloud_config");
    }
    match &san.value.general_names[0] {
        GeneralName::URI(u) if *u == expected_uri => {}
        _ => return Err("cloud_config"),
    }

    // Verify ExtendedKeyUsage contains ClientAuth
    let eku = leaf
        .extended_key_usage()
        .map_err(|_| "cloud_config")?
        .ok_or("cloud_config")?;
    if !eku.value.client_auth {
        return Err("cloud_config");
    }

    // Verify DeviceCA commit receipt signature
    let rcpt = decode_strict_b64(&b.receipt_base64).ok_or("cloud_config")?;
    let rcpt_sig = Signature::from_slice(&rcpt).map_err(|_| "cloud_config")?;
    ca_vk
        .verify(&receipt_bytes(&s.request, b, &leaf_der), &rcpt_sig)
        .map_err(|_| "cloud_config")?;

    let not_before = leaf.validity().not_before.to_datetime();
    let not_after = leaf.validity().not_after.to_datetime();
    if check_wall_clock {
        let now = OffsetDateTime::now_utc();
        if now < not_before || now >= not_after {
            return Err("certificate_expired");
        }
    }

    Ok(Some(not_after))
}

fn read_saved_file(path: &Path) -> Result<Option<SavedCloud>, &'static str> {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("cloud_config"),
    };
    if !meta.file_type().is_file() || (meta.mode() & 0o777) != 0o600 || meta.size() > 65536 {
        return Err("cloud_config");
    }
    let bytes = fs::read(path).map_err(|_| "cloud_config")?;
    let _ = strict_json::parse_object(
        &bytes,
        &["schema_version", "request", "response"],
        &["activation"],
    )
    .map_err(|_| "cloud_config")?;
    let saved: SavedCloud = serde_json::from_slice(&bytes).map_err(|_| "cloud_config")?;
    Ok(Some(saved))
}

fn persist_saved(path: &Path, saved: &SavedCloud) -> Result<(), &'static str> {
    let dir = path.parent().ok_or("cloud_config")?;
    let dm = fs::symlink_metadata(dir).map_err(|_| "cloud_config")?;
    if !dm.is_dir() || dm.file_type().is_symlink() || (dm.mode() & 0o777) != 0o700 {
        return Err("cloud_config");
    }
    let data = serde_json::to_vec(saved).map_err(|_| "cloud_config")?;
    let suffix = uuid_v4().map_err(|_| "cloud_config")?;
    let tmp = dir.join(format!(".cloud-{suffix}"));
    {
        let mut f = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|_| "cloud_config")?;
        f.write_all(&data).map_err(|_| "cloud_config")?;
        f.sync_all().map_err(|_| "cloud_config")?;
    }
    fs::rename(&tmp, path).map_err(|_| {
        let _ = fs::remove_file(&tmp);
        "cloud_config"
    })?;
    if let Ok(d) = fs::File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

struct ProvInner {
    config: Option<SavedCloud>,
    pending: Option<SavedCloud>,
    status: CloudStatus,
    cert_expiry: Option<OffsetDateTime>,
}

pub struct Provisioner {
    profile: String,
    pub identity: Identity,
    path: PathBuf,
    inner: Mutex<ProvInner>,
    changed: Arc<tokio::sync::Notify>,
}

impl Provisioner {
    pub fn open(identity: Identity, path: PathBuf, profile: String) -> Arc<Self> {
        let mut status = CloudStatus {
            configured: false,
            connected: false,
            server_id: String::new(),
            module_id: identity.module_id.clone(),
            connection_epoch: String::new(),
            last_connected_at: None,
            last_error: String::new(),
            certificate_expires_at: None,
        };
        let mut config = None;
        let mut pending = None;
        let mut cert_expiry = None;

        match read_saved_file(&path) {
            Ok(Some(s)) => {
                // Structural check without wall-clock rejection so 1980 cold-boot RTC still loads!
                match validate_saved(&identity, &s, true, false) {
                    Ok(exp) => {
                        status.configured = true;
                        status.server_id = s.request.server_id.clone();
                        status.certificate_expires_at =
                            exp.and_then(|t| t.format(&Rfc3339).ok());
                        cert_expiry = exp;
                        config = Some(s);
                    }
                    Err(_) => {
                        status.last_error = "cloud_config".into();
                    }
                }
            }
            Ok(None) => {}
            Err(_) => {
                status.last_error = "cloud_config".into();
            }
        }

        if status.last_error.is_empty() {
            let pending_path = PathBuf::from(format!("{}.pending", path.display()));
            match read_saved_file(&pending_path) {
                Ok(Some(p)) => {
                    if config
                        .as_ref()
                        .is_some_and(|c| c.request.request_id == p.request.request_id)
                    {
                        let _ = fs::remove_file(&pending_path);
                    } else if validate_saved(&identity, &p, false, false).is_ok() {
                        pending = Some(p);
                    } else {
                        status.last_error = "cloud_config".into();
                    }
                }
                Ok(None) => {}
                Err(_) => {
                    status.last_error = "cloud_config".into();
                }
            }
        }

        Arc::new(Self {
            profile,
            identity,
            path,
            inner: Mutex::new(ProvInner {
                config,
                pending,
                status,
                cert_expiry,
            }),
            changed: Arc::new(tokio::sync::Notify::new()),
        })
    }

    pub fn profile(&self) -> &str {
        &self.profile
    }

    pub fn changed(&self) -> Arc<tokio::sync::Notify> {
        self.changed.clone()
    }

    pub fn current_config(&self) -> Option<SavedCloud> {
        self.inner.lock().unwrap().config.clone()
    }

    pub fn view(&self) -> CloudStatus {
        self.inner.lock().unwrap().status.clone()
    }

    pub fn set_connection_state(&self, connected: bool, epoch: &str, err_code: &str) {
        let mut g = self.inner.lock().unwrap();
        g.status.connected = connected;
        g.status.connection_epoch = epoch.to_string();
        g.status.last_error = err_code.to_string();
        if connected {
            g.status.last_connected_at = OffsetDateTime::now_utc().format(&Rfc3339).ok();
        }
    }

    pub fn validate_for_connect(&self, cfg: &SavedCloud) -> Result<OffsetDateTime, &'static str> {
        validate_saved(&self.identity, cfg, true, true)?.ok_or("certificate_invalid")
    }

    pub fn renewal_request(&self) -> Option<(String, String, String)> {
        let g = self.inner.lock().unwrap();
        let cfg = g.config.as_ref()?;
        let uri = format!(
            "urn:airsim:{}:module:{}",
            cfg.request.server_id, self.identity.module_id
        );
        let der = build_ed25519_csr_der(&self.identity, &uri);
        Some((
            cfg.request.request_id.clone(),
            cfg.request.nonce.clone(),
            pem_encode("CERTIFICATE REQUEST", &der),
        ))
    }

    pub fn renew(&self, bundle: Bundle) -> Result<OffsetDateTime, &'static str> {
        let mut g = self.inner.lock().unwrap();
        if g.status.last_error == "cloud_config" {
            return Err("cloud_config");
        }
        let mut next = g.config.clone().ok_or("cloud_config")?;
        next.activation = Some(bundle);
        let exp = validate_saved(&self.identity, &next, true, true)?.ok_or("cloud_config")?;
        persist_saved(&self.path, &next)?;
        g.config = Some(next);
        g.cert_expiry = Some(exp);
        g.status.certificate_expires_at = exp.format(&Rfc3339).ok();
        Ok(exp)
    }

    pub fn prepare(&self, req: Prepare) -> (Option<Prepared>, u16) {
        let mut g = self.inner.lock().unwrap();
        if g.status.last_error == "cloud_config" {
            return (None, 503);
        }
        if let Some(ref cfg) = g.config {
            if cfg.request == req {
                return (Some(cfg.response.clone()), 200);
            }
            if g.cert_expiry
                .map(|exp| OffsetDateTime::now_utc() < exp)
                .unwrap_or(true)
            {
                return (None, 409);
            }
        }
        if let Some(ref pend) = g.pending {
            if pend.request == req {
                return (Some(pend.response.clone()), 200);
            }
            let expired = parse_rfc3339(&pend.request.expires_at)
                .map(|t| OffsetDateTime::now_utc() >= t)
                .unwrap_or(true);
            if expired {
                g.pending = None;
                let _ = fs::remove_file(format!("{}.pending", self.path.display()));
            } else {
                return (None, 409);
            }
        }

        // Validate Prepare freshness (expires in (0, 10m])
        let Some(exp) = parse_rfc3339(&req.expires_at) else {
            return (None, 400);
        };
        let rem = exp - OffsetDateTime::now_utc();
        if rem.is_negative() || rem.is_zero() || rem > time::Duration::minutes(10) {
            return (None, 400);
        }

        let uri = format!("urn:airsim:{}:module:{}", req.server_id, self.identity.module_id);
        let csr_der = build_ed25519_csr_der(&self.identity, &uri);
        let sig = self
            .identity
            .sign(&proof_bytes(&req, &self.identity.module_id, &csr_der));
        let b64 = base64::engine::general_purpose::STANDARD;
        let resp = Prepared {
            request_id: req.request_id.clone(),
            module_id: self.identity.module_id.clone(),
            public_key_base64: self.identity.public_key_base64(),
            csr_pem: pem_encode("CERTIFICATE REQUEST", &csr_der),
            proof_base64: b64.encode(sig.to_bytes()),
        };
        let saved = SavedCloud {
            schema_version: 1,
            request: req,
            response: resp.clone(),
            activation: None,
        };
        if validate_saved(&self.identity, &saved, false, false).is_err() {
            return (None, 400);
        }
        let pending_path = PathBuf::from(format!("{}.pending", self.path.display()));
        if persist_saved(&pending_path, &saved).is_err() {
            return (None, 503);
        }
        g.pending = Some(saved);
        (Some(resp), 200)
    }

    pub fn activate(&self, bundle: Bundle) -> u16 {
        let mut g = self.inner.lock().unwrap();
        if g.status.last_error == "cloud_config" {
            return 503;
        }
        if let Some(ref cfg) = g.config {
            if cfg.activation.as_ref() == Some(&bundle) {
                return 200;
            }
            if g.pending.is_none()
                || g.cert_expiry
                    .map(|exp| OffsetDateTime::now_utc() < exp)
                    .unwrap_or(true)
            {
                return 409;
            }
        }
        let Some(mut s) = g.pending.clone() else {
            return 409;
        };
        if parse_rfc3339(&s.request.expires_at)
            .map(|t| OffsetDateTime::now_utc() >= t)
            .unwrap_or(true)
        {
            return 400;
        }
        s.activation = Some(bundle);
        let Ok(Some(exp)) = validate_saved(&self.identity, &s, true, true) else {
            return 400;
        };
        if persist_saved(&self.path, &s).is_err() {
            return 503;
        }
        g.status.configured = true;
        g.status.server_id = s.request.server_id.clone();
        g.status.certificate_expires_at = exp.format(&Rfc3339).ok();
        g.status.last_error.clear();
        g.cert_expiry = Some(exp);
        g.config = Some(s);
        g.pending = None;
        let _ = fs::remove_file(format!("{}.pending", self.path.display()));
        drop(g);
        self.changed.notify_waiters();
        200
    }

    /// Handle `/v2/local/cloud*` and `/v2/local/pairing*` local API routes.
    pub fn handle_local_route(&self, req: &HttpRequest) -> Option<HttpResponse> {
        match req.path.as_str() {
            "/v2/local/cloud" => {
                if req.method != "GET" {
                    return Some(HttpResponse::empty(405));
                }
                Some(HttpResponse::json(200, &self.view()))
            }
            "/v2/local/cloud/prepare" => {
                if req.method != "POST" {
                    return Some(HttpResponse::empty(405));
                }
                let Ok(p) = strict_json::decode_exact_csv::<Prepare>(
                    &req.body,
                    "request_id,server_id,api_origin,device_origin,media_origin,device_ca_pem,server_ca_pem,nonce,expires_at",
                    "",
                ) else {
                    return Some(HttpResponse::empty(400));
                };
                match self.prepare(p) {
                    (Some(out), code) => Some(HttpResponse::json(code, &out)),
                    (None, code) => Some(HttpResponse::empty(code)),
                }
            }
            "/v2/local/cloud/activate" => {
                if req.method != "POST" {
                    return Some(HttpResponse::empty(405));
                }
                let Ok(b) = strict_json::decode_exact_csv::<Bundle>(
                    &req.body,
                    "request_id,server_id,module_id,certificate_pem,receipt_base64",
                    "",
                ) else {
                    return Some(HttpResponse::empty(400));
                };
                Some(HttpResponse::empty(self.activate(b)))
            }
            "/v2/local/pairing" => {
                if req.method != "GET" {
                    return Some(HttpResponse::json(
                        405,
                        &serde_json::json!({"error": "pairing_method_not_allowed"}),
                    ));
                }
                if !req.query.is_empty() {
                    return Some(HttpResponse::json(
                        400,
                        &serde_json::json!({"error": "pairing_request_invalid"}),
                    ));
                }
                Some(self.pairing_view_response())
            }
            "/v2/local/pairing/authorize" => {
                if req.method != "POST" {
                    return Some(HttpResponse::json(
                        405,
                        &serde_json::json!({"error": "pairing_method_not_allowed"}),
                    ));
                }
                if !req.query.is_empty() || req.header("content-type") != "application/json" {
                    return Some(HttpResponse::json(
                        400,
                        &serde_json::json!({"error": "pairing_request_invalid"}),
                    ));
                }
                let Ok(pr) = strict_json::decode_exact_csv::<PairingRequest>(
                    &req.body,
                    "request_id,server_id,module_id,nonce,expires_at,poll_token_hash",
                    "",
                ) else {
                    return Some(HttpResponse::json(
                        400,
                        &serde_json::json!({"error": "pairing_request_invalid"}),
                    ));
                };
                Some(self.authorize_pairing_response(pr))
            }
            _ => None,
        }
    }

    fn pairing_view_response(&self) -> HttpResponse {
        let g = self.inner.lock().unwrap();
        let mut out = PairingStatus {
            module_id: self.identity.module_id.clone(),
            public_key_base64: self.identity.public_key_base64(),
            profile: self.profile.clone(),
            configured: false,
            server_id: String::new(),
            api_origin: String::new(),
            media_origin: String::new(),
            connected: false,
            certificate_expires_at: None,
        };
        if g.status.last_error == "cloud_config" {
            return HttpResponse::json(503, &serde_json::json!({"error": "pairing_config_invalid"}));
        }
        let Some(ref cfg) = g.config else {
            return HttpResponse::json(200, &out);
        };
        match validate_saved(&self.identity, cfg, true, true) {
            Ok(Some(exp)) => {
                out.configured = true;
                out.server_id = cfg.request.server_id.clone();
                out.api_origin = cfg.request.api_origin.clone();
                out.media_origin = cfg.request.media_origin.clone();
                out.connected = g.status.connected;
                out.certificate_expires_at = exp.format(&Rfc3339).ok();
                HttpResponse::json(200, &out)
            }
            Err("certificate_expired") => {
                HttpResponse::json(410, &serde_json::json!({"error": "pairing_certificate_expired"}))
            }
            _ => HttpResponse::json(503, &serde_json::json!({"error": "pairing_config_invalid"})),
        }
    }

    fn authorize_pairing_response(&self, r: PairingRequest) -> HttpResponse {
        let Some(exp) = parse_rfc3339(&r.expires_at) else {
            return HttpResponse::json(400, &serde_json::json!({"error": "pairing_request_invalid"}));
        };
        if !is_valid_uuid_v4(&r.request_id)
            || !is_valid_uuid_v4(&r.server_id)
            || !is_valid_uuid_v4(&r.module_id)
            || !is_hex32(&r.nonce)
            || !is_hex32(&r.poll_token_hash)
            || !r.expires_at.ends_with('Z')
        {
            return HttpResponse::json(400, &serde_json::json!({"error": "pairing_request_invalid"}));
        }
        let rem = exp - OffsetDateTime::now_utc();
        if rem.is_negative() || rem.is_zero() {
            return HttpResponse::json(410, &serde_json::json!({"error": "pairing_request_expired"}));
        }
        if rem > time::Duration::seconds(305) {
            return HttpResponse::json(400, &serde_json::json!({"error": "pairing_request_invalid"}));
        }
        let g = self.inner.lock().unwrap();
        let Some(ref cfg) = g.config else {
            return HttpResponse::json(409, &serde_json::json!({"error": "pairing_unconfigured"}));
        };
        if let Err(e) = validate_saved(&self.identity, cfg, true, true) {
            let (code, err) = if e == "certificate_expired" {
                (410, "pairing_certificate_expired")
            } else {
                (503, "pairing_config_invalid")
            };
            return HttpResponse::json(code, &serde_json::json!({"error": err}));
        }
        if r.module_id != self.identity.module_id || r.server_id != cfg.request.server_id {
            return HttpResponse::json(409, &serde_json::json!({"error": "pairing_binding_mismatch"}));
        }
        let sig = self.identity.sign(&pairing_bytes(&r));
        let b64 = base64::engine::general_purpose::STANDARD;
        HttpResponse::json(
            200,
            &PairingProof {
                request_id: r.request_id,
                module_id: self.identity.module_id.clone(),
                public_key_base64: self.identity.public_key_base64(),
                proof_base64: b64.encode(sig.to_bytes()),
            },
        )
    }

    /// Build a `rustls::ClientConfig` (pure-Rust `rustls_rustcrypto` provider) trusting either
    /// `cfg.request.server_ca_pem` or (`SSL_CERT_DIR` + `webpki-roots`), optionally with Ed25519 mTLS.
    pub fn build_tls_client_config(
        &self,
        cfg: &SavedCloud,
        with_client_cert: bool,
    ) -> Result<Arc<ClientConfig>, String> {
        let mut root_store = RootCertStore::empty();
        if !cfg.request.server_ca_pem.trim().is_empty() {
            let mut cursor = std::io::Cursor::new(cfg.request.server_ca_pem.as_bytes());
            for cert in rustls_pemfile::certs(&mut cursor) {
                let c = cert.map_err(|e| format!("server_ca_pem: {e}"))?;
                root_store.add(c).map_err(|e| format!("root_add: {e}"))?;
            }
        } else {
            // Load Mozilla roots (includes ISRG Root X1) AND any PEMs in SSL_CERT_DIR / SSL_CERT_FILE.
            root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            if let Ok(dir) = std::env::var("SSL_CERT_DIR") {
                if let Ok(entries) = fs::read_dir(dir) {
                    for ent in entries.flatten() {
                        if let Ok(bytes) = fs::read(ent.path()) {
                            let mut cur = std::io::Cursor::new(&bytes);
                            for c in rustls_pemfile::certs(&mut cur).flatten() {
                                let _ = root_store.add(c);
                            }
                        }
                    }
                }
            }
            if let Ok(file) = std::env::var("SSL_CERT_FILE") {
                if let Ok(bytes) = fs::read(file) {
                    let mut cur = std::io::Cursor::new(&bytes);
                    for c in rustls_pemfile::certs(&mut cur).flatten() {
                        let _ = root_store.add(c);
                    }
                }
            }
        }

        let provider = Arc::new(rustls_rustcrypto::provider());
        let builder = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map_err(|e| format!("tls_proto: {e}"))?
            .with_root_certificates(root_store);

        let client_cfg = if with_client_cert {
            let act = cfg.activation.as_ref().ok_or("no_activation")?;
            let leaf_der = parse_single_cert_pem(&act.certificate_pem)
                .ok_or_else(|| "bad_leaf_pem".to_string())?;
            let certs = vec![CertificateDer::from(leaf_der)];
            let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.identity.pkcs8_der()));
            builder
                .with_client_auth_cert(certs, key)
                .map_err(|e| format!("tls_client_auth: {e}"))?
        } else {
            builder.with_no_client_auth()
        };

        Ok(Arc::new(client_cfg))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::load_or_create;

    #[test]
    fn ed25519_csr_der_parses_cleanly_with_x509_parser() {
        let dir = std::env::temp_dir().join(format!("airsim-csr-test-{}", uuid_v4().unwrap()));
        let id = load_or_create(&dir).unwrap();
        let uri = format!("urn:airsim:{}:module:{}", uuid_v4().unwrap(), id.module_id);
        let der = build_ed25519_csr_der(&id, &uri);
        let (_, csr) =
            x509_parser::certification_request::X509CertificationRequest::from_der(&der).unwrap();
        assert_eq!(
            csr.certification_request_info.subject_pki.subject_public_key.data.as_ref(),
            id.public_key_bytes()
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
