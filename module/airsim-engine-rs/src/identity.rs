use crate::strict_json;
use base64::Engine as _;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    schema_version: i32,
    module_id: String,
    algorithm: String,
    seed_base64: String,
    public_key_base64: String,
}

#[derive(Clone)]
pub struct Identity {
    pub module_id: String,
    key: SigningKey,
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("module_id", &self.module_id)
            .finish_non_exhaustive()
    }
}

pub fn is_valid_uuid_v4(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 36 {
        return false;
    }
    for (i, &c) in b.iter().enumerate() {
        match i {
            8 | 13 | 18 | 23 => {
                if c != b'-' {
                    return false;
                }
            }
            14 => {
                if c != b'4' {
                    return false;
                }
            }
            19 => {
                if !matches!(c, b'8' | b'9' | b'a' | b'b') {
                    return false;
                }
            }
            _ => {
                if !matches!(c, b'0'..=b'9' | b'a'..=b'f') {
                    return false;
                }
            }
        }
    }
    true
}

pub fn uuid_v4() -> Result<String, String> {
    let mut b = [0u8; 16];
    getrandom::getrandom(&mut b).map_err(|e| format!("random_failed: {e}"))?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
    ))
}

impl Identity {
    pub fn public_key_bytes(&self) -> [u8; 32] {
        self.key.verifying_key().to_bytes()
    }

    pub fn public_key_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.public_key_bytes())
    }

    pub fn verifying_key(&self) -> VerifyingKey {
        self.key.verifying_key()
    }

    pub fn signing_key(&self) -> &SigningKey {
        &self.key
    }

    pub fn sign(&self, msg: &[u8]) -> Signature {
        self.key.sign(msg)
    }

    /// Exact match with Go `identity.Identity.CommandDigest`:
    /// HMAC-SHA256(key = seed, msg = "airsim-r2-command-v1\0" + action + "\0" + payload)
    pub fn command_digest(&self, action: &str, payload: &[u8]) -> String {
        let mut mac =
            HmacSha256::new_from_slice(&self.key.to_bytes()).expect("hmac key size");
        mac.update(b"airsim-r2-command-v1\0");
        mac.update(action.as_bytes());
        mac.update(&[0]);
        mac.update(payload);
        hex::encode(mac.finalize().into_bytes())
    }

    /// PKCS#8 DER bytes for the Ed25519 private key (RFC 8410 v1).
    pub fn pkcs8_der(&self) -> Vec<u8> {
        // RFC 8410 Ed25519 PKCS#8 OneAsymmetricKey (48 bytes fixed structure):
        // 30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20 <32-byte seed>
        let mut der = Vec::with_capacity(48);
        der.extend_from_slice(&[
            0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22,
            0x04, 0x20,
        ]);
        der.extend_from_slice(&self.key.to_bytes());
        der
    }
}

fn decode_identity(bytes: &[u8]) -> Result<Identity, String> {
    if bytes.len() > 4096 {
        return Err("identity_invalid".into());
    }
    let rec: Record = strict_json::decode_exact(
        bytes,
        &[
            "schema_version",
            "module_id",
            "algorithm",
            "seed_base64",
            "public_key_base64",
        ],
        &[],
    )
    .map_err(|_| "identity_invalid".to_string())?;

    if rec.schema_version != 1 || rec.algorithm != "ed25519" || !is_valid_uuid_v4(&rec.module_id) {
        return Err("identity_invalid".into());
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let seed = b64
        .decode(rec.seed_base64.as_bytes())
        .map_err(|_| "identity_invalid".to_string())?;
    if seed.len() != 32 || b64.encode(&seed) != rec.seed_base64 {
        return Err("identity_invalid".into());
    }
    let pub_bytes = b64
        .decode(rec.public_key_base64.as_bytes())
        .map_err(|_| "identity_invalid".to_string())?;
    if pub_bytes.len() != 32 || b64.encode(&pub_bytes) != rec.public_key_base64 {
        return Err("identity_invalid".into());
    }
    let seed_arr: [u8; 32] = seed.try_into().map_err(|_| "identity_invalid".to_string())?;
    let key = SigningKey::from_bytes(&seed_arr);
    if key.verifying_key().to_bytes() != pub_bytes.as_slice() {
        return Err("identity_invalid".into());
    }
    Ok(Identity {
        module_id: rec.module_id,
        key,
    })
}

pub fn load_or_create(dir: &Path) -> Result<Identity, String> {
    if !dir.exists() {
        fs::create_dir_all(dir).map_err(|_| "identity_invalid".to_string())?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
            .map_err(|_| "identity_invalid".to_string())?;
    }
    let meta = fs::symlink_metadata(dir).map_err(|_| "identity_invalid".to_string())?;
    if !meta.is_dir() || meta.file_type().is_symlink() || (meta.mode() & 0o777) != 0o700 {
        return Err("identity_invalid".into());
    }
    let path = dir.join("identity.json");
    match fs::symlink_metadata(&path) {
        Ok(im) => {
            if !im.file_type().is_file() || (im.mode() & 0o777) != 0o600 || im.size() > 4096 {
                return Err("identity_invalid".into());
            }
            let bytes = fs::read(&path).map_err(|_| "identity_invalid".to_string())?;
            return decode_identity(&bytes);
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("identity_invalid".into()),
    }

    // Reject orphaned .identity-* temp files if identity.json does not exist.
    for entry in fs::read_dir(dir).map_err(|_| "identity_invalid".to_string())? {
        let entry = entry.map_err(|_| "identity_invalid".to_string())?;
        if entry
            .file_name()
            .to_str()
            .is_some_and(|n| n.starts_with(".identity-"))
        {
            return Err("identity_invalid".into());
        }
    }

    let module_id = uuid_v4()?;
    let mut seed = [0u8; 32];
    getrandom::getrandom(&mut seed).map_err(|e| format!("random_failed: {e}"))?;
    let key = SigningKey::from_bytes(&seed);
    let b64 = base64::engine::general_purpose::STANDARD;
    let rec = Record {
        schema_version: 1,
        module_id: module_id.clone(),
        algorithm: "ed25519".into(),
        seed_base64: b64.encode(seed),
        public_key_base64: b64.encode(key.verifying_key().to_bytes()),
    };
    let encoded = serde_json::to_vec(&rec).map_err(|e| e.to_string())?;
    let suffix = uuid_v4()?;
    let tmp_path = dir.join(format!(".identity-{suffix}"));
    {
        let mut f = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&tmp_path)
            .map_err(|e| e.to_string())?;
        f.write_all(&encoded).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
    }
    fs::hard_link(&tmp_path, &path).map_err(|e| e.to_string())?;
    let _ = fs::remove_file(&tmp_path);
    if let Ok(d) = fs::File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(Identity { module_id, key })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_digest() {
        let dir = std::env::temp_dir().join(format!("airsim-id-test-{}", uuid_v4().unwrap()));
        let id1 = load_or_create(&dir).unwrap();
        let id2 = load_or_create(&dir).unwrap();
        assert_eq!(id1.module_id, id2.module_id);
        assert_eq!(id1.public_key_bytes(), id2.public_key_bytes());
        assert_eq!(
            id1.command_digest("call.dial", br#"{"number":"10086"}"#),
            id2.command_digest("call.dial", br#"{"number":"10086"}"#)
        );
        assert_eq!(id1.pkcs8_der().len(), 48);
        let _ = fs::remove_dir_all(&dir);
    }
}
