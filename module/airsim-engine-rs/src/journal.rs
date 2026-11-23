use crate::identity::{is_valid_uuid_v4, uuid_v4};
use crate::strict_json;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

pub const CAPACITY: usize = 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Record {
    pub command_id: String,
    pub request_digest: String,
    pub action: String,
    pub state: String,
    pub result_code: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub call_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub message_id: String,
    pub created_at: String,
    pub updated_at: String,
    pub agent_boot_id: String,
    pub backend_epoch: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct FileData {
    schema_version: i32,
    records: Vec<Record>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JournalError {
    Unavailable,
    Full,
    Conflict,
}

impl std::fmt::Display for JournalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => f.write_str("journal_unavailable"),
            Self::Full => f.write_str("journal_full"),
            Self::Conflict => f.write_str("command_conflict"),
        }
    }
}

pub fn now_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into())
}

pub fn parse_rfc3339(s: &str) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(s, &Rfc3339).ok()
}

pub fn terminal_state(state: &str) -> bool {
    matches!(
        state,
        "accepted" | "observed" | "failed" | "outcome_unknown" | "expired"
    )
}

fn valid_record(r: &Record) -> bool {
    if !is_valid_uuid_v4(&r.command_id)
        || !is_valid_uuid_v4(&r.agent_boot_id)
        || !is_valid_uuid_v4(&r.backend_epoch)
        || parse_rfc3339(&r.created_at).is_none()
        || parse_rfc3339(&r.updated_at).is_none()
    {
        return false;
    }
    if r.request_digest.len() != 64 || hex::decode(&r.request_digest).is_err() {
        return false;
    }
    if !r.call_id.is_empty() && !is_valid_uuid_v4(&r.call_id) {
        return false;
    }
    if !r.message_id.is_empty() && !is_valid_uuid_v4(&r.message_id) {
        return false;
    }
    if !matches!(
        r.action.as_str(),
        "call.dial" | "call.answer" | "call.hangup" | "call.dtmf" | "sms.send"
    ) {
        return false;
    }
    if !matches!(
        r.state.as_str(),
        "prepared" | "dispatched" | "accepted" | "observed" | "failed" | "outcome_unknown" | "expired"
    ) {
        return false;
    }
    r.result_code.len() <= 64
        && r.result_code
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c == b'_')
}

#[derive(Debug)]
struct Inner {
    dir: PathBuf,
    records: HashMap<String, Record>,
    failed: bool,
}

#[derive(Debug)]
pub struct Store {
    inner: Mutex<Inner>,
}

impl Store {
    pub fn open(dir: &Path) -> Result<Self, (Self, JournalError)> {
        let mut inner = Inner {
            dir: dir.to_path_buf(),
            records: HashMap::new(),
            failed: false,
        };
        match Self::open_inner(&mut inner) {
            Ok(()) => Ok(Self {
                inner: Mutex::new(inner),
            }),
            Err(e) => {
                inner.failed = true;
                Err((
                    Self {
                        inner: Mutex::new(inner),
                    },
                    e,
                ))
            }
        }
    }

    fn open_inner(inner: &mut Inner) -> Result<(), JournalError> {
        let dir = &inner.dir;
        if !dir.exists() {
            fs::create_dir_all(dir).map_err(|_| JournalError::Unavailable)?;
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
                .map_err(|_| JournalError::Unavailable)?;
        }
        let meta = fs::symlink_metadata(dir).map_err(|_| JournalError::Unavailable)?;
        if !meta.is_dir() || (meta.mode() & 0o777) != 0o700 {
            return Err(JournalError::Unavailable);
        }

        let mut leftovers = Vec::new();
        for entry in fs::read_dir(dir).map_err(|_| JournalError::Unavailable)? {
            let entry = entry.map_err(|_| JournalError::Unavailable)?;
            if entry
                .file_name()
                .to_str()
                .is_some_and(|n| n.starts_with(".commands-"))
            {
                leftovers.push(entry.path());
            }
        }

        let path = dir.join("commands.json");
        let file_meta = match fs::symlink_metadata(&path) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if !leftovers.is_empty() {
                    return Err(JournalError::Unavailable);
                }
                return Ok(());
            }
            Err(_) => return Err(JournalError::Unavailable),
        };
        if !file_meta.file_type().is_file()
            || (file_meta.mode() & 0o777) != 0o600
            || file_meta.size() > (2 << 20)
        {
            return Err(JournalError::Unavailable);
        }

        for orphan in &leftovers {
            let om = fs::symlink_metadata(orphan).map_err(|_| JournalError::Unavailable)?;
            if !om.file_type().is_file() {
                return Err(JournalError::Unavailable);
            }
            fs::remove_file(orphan).map_err(|_| JournalError::Unavailable)?;
        }
        if !leftovers.is_empty() {
            if let Ok(d) = fs::File::open(dir) {
                let _ = d.sync_all();
            }
        }

        let bytes = fs::read(&path).map_err(|_| JournalError::Unavailable)?;
        if bytes.len() > (2 << 20) {
            return Err(JournalError::Unavailable);
        }
        let obj = strict_json::parse_object(&bytes, &["schema_version", "records"], &[])
            .map_err(|_| JournalError::Unavailable)?;
        if obj.get("schema_version").and_then(|v| v.as_i64()) != Some(1) {
            return Err(JournalError::Unavailable);
        }
        let raw_records = obj
            .get("records")
            .and_then(|v| v.as_array())
            .ok_or(JournalError::Unavailable)?;
        if raw_records.len() > CAPACITY {
            return Err(JournalError::Unavailable);
        }

        let mut changed = false;
        let now = now_rfc3339();
        for item in raw_records {
            let item_bytes = serde_json::to_vec(item).map_err(|_| JournalError::Unavailable)?;
            let mut rec: Record = strict_json::decode_exact(
                &item_bytes,
                &[
                    "command_id",
                    "request_digest",
                    "action",
                    "state",
                    "result_code",
                    "created_at",
                    "updated_at",
                    "agent_boot_id",
                    "backend_epoch",
                ],
                &["call_id", "message_id"],
            )
            .map_err(|_| JournalError::Unavailable)?;
            if !valid_record(&rec) || inner.records.contains_key(&rec.command_id) {
                return Err(JournalError::Unavailable);
            }
            match rec.state.as_str() {
                "prepared" => {
                    rec.state = "expired".into();
                    rec.result_code = "restart_before_dispatch".into();
                    rec.updated_at = now.clone();
                    changed = true;
                }
                "dispatched" => {
                    rec.state = "outcome_unknown".into();
                    rec.result_code = "restart_after_dispatch".into();
                    rec.updated_at = now.clone();
                    changed = true;
                }
                _ => {}
            }
            inner.records.insert(rec.command_id.clone(), rec);
        }
        if changed {
            Self::persist(inner)?;
        }
        Ok(())
    }

    fn persist(inner: &Inner) -> Result<(), JournalError> {
        let mut records: Vec<Record> = inner.records.values().cloned().collect();
        records.sort_by(|a, b| a.command_id.cmp(&b.command_id));
        let data = serde_json::to_vec(&FileData {
            schema_version: 1,
            records,
        })
        .map_err(|_| JournalError::Unavailable)?;

        let suffix = uuid_v4().map_err(|_| JournalError::Unavailable)?;
        let tmp = inner.dir.join(format!(".commands-{suffix}"));
        {
            let mut f = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&tmp)
                .map_err(|_| JournalError::Unavailable)?;
            f.write_all(&data).map_err(|_| JournalError::Unavailable)?;
            f.sync_all().map_err(|_| JournalError::Unavailable)?;
        }
        let target = inner.dir.join("commands.json");
        fs::rename(&tmp, &target).map_err(|_| {
            let _ = fs::remove_file(&tmp);
            JournalError::Unavailable
        })?;
        if let Ok(d) = fs::File::open(&inner.dir) {
            let _ = d.sync_all();
        }
        Ok(())
    }

    pub fn get(&self, id: &str) -> Option<Record> {
        self.inner.lock().unwrap().records.get(id).cloned()
    }

    pub fn remaining(&self) -> u64 {
        let g = self.inner.lock().unwrap();
        if g.failed {
            return 0;
        }
        (CAPACITY.saturating_sub(g.records.len())) as u64
    }

    pub fn is_failed(&self) -> bool {
        self.inner.lock().unwrap().failed
    }

    pub fn put(&self, rec: Record) -> Result<(), JournalError> {
        let mut g = self.inner.lock().unwrap();
        if g.failed || !valid_record(&rec) {
            return Err(JournalError::Unavailable);
        }
        if let Some(prev) = g.records.get(&rec.command_id) {
            if prev.request_digest != rec.request_digest || prev.action != rec.action {
                return Err(JournalError::Conflict);
            }
        } else if g.records.len() >= CAPACITY {
            // Evict oldest terminal record.
            let oldest_terminal = g
                .records
                .values()
                .filter(|r| terminal_state(&r.state))
                .min_by(|a, b| a.updated_at.cmp(&b.updated_at))
                .map(|r| r.command_id.clone());
            match oldest_terminal {
                Some(evict_id) => {
                    g.records.remove(&evict_id);
                }
                None => return Err(JournalError::Full),
            }
        }
        let backup = g.records.insert(rec.command_id.clone(), rec.clone());
        if let Err(e) = Self::persist(&g) {
            match backup {
                Some(old) => {
                    g.records.insert(rec.command_id, old);
                }
                None => {
                    g.records.remove(&rec.command_id);
                }
            }
            g.failed = true;
            return Err(e);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restart_transitions_and_orphan_cleanup() {
        let dir = std::env::temp_dir().join(format!("airsim-jrn-test-{}", uuid_v4().unwrap()));
        let store = Store::open(&dir).unwrap();
        let boot = uuid_v4().unwrap();
        let epoch = uuid_v4().unwrap();
        let c1 = uuid_v4().unwrap();
        let c2 = uuid_v4().unwrap();
        let now = now_rfc3339();
        let digest = "a".repeat(64);
        store
            .put(Record {
                command_id: c1.clone(),
                request_digest: digest.clone(),
                action: "call.dial".into(),
                state: "prepared".into(),
                result_code: "".into(),
                call_id: "".into(),
                message_id: "".into(),
                created_at: now.clone(),
                updated_at: now.clone(),
                agent_boot_id: boot.clone(),
                backend_epoch: epoch.clone(),
            })
            .unwrap();
        store
            .put(Record {
                command_id: c2.clone(),
                request_digest: digest,
                action: "sms.send".into(),
                state: "dispatched".into(),
                result_code: "".into(),
                call_id: "".into(),
                message_id: "".into(),
                created_at: now.clone(),
                updated_at: now,
                agent_boot_id: boot,
                backend_epoch: epoch,
            })
            .unwrap();
        // Leave an orphan temp file; reopen must clean it and transition states.
        fs::write(dir.join(".commands-orphan"), b"partial").unwrap();
        let reopened = Store::open(&dir).unwrap();
        assert_eq!(reopened.get(&c1).unwrap().state, "expired");
        assert_eq!(reopened.get(&c2).unwrap().state, "outcome_unknown");
        assert!(!dir.join(".commands-orphan").exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
