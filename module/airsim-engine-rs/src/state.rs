use crate::journal::now_rfc3339;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::RwLock;
use std::time::{Duration, Instant};

pub const STALE_AFTER: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HalField {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl HalField {
    pub fn available(source: &str, data: Value) -> Self {
        Self {
            status: "available".into(),
            source: Some(source.into()),
            observed_at: Some(now_rfc3339()),
            error_code: None,
            data: Some(data),
        }
    }

    pub fn unavailable(source: &str, code: &str) -> Self {
        Self {
            status: "unavailable".into(),
            source: if source.is_empty() {
                None
            } else {
                Some(source.into())
            },
            observed_at: None,
            error_code: Some(code.into()),
            data: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HalCapability {
    pub support: String,
    pub readiness: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub schema_version: i32,
    pub module_id: String,
    pub agent_boot_id: String,
    pub revision: u64,
    pub observed_at: String,
    pub freshness: String,
    pub scope: String,
    pub voice_ready: bool,
    pub identity_state: String,
    pub fields: BTreeMap<String, HalField>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Ready {
    pub ready: bool,
    pub scope: String,
    pub degraded: bool,
    pub voice_ready: bool,
    pub reasons: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Capabilities {
    pub schema_version: i32,
    pub module_id: String,
    pub profile: String,
    pub capabilities: BTreeMap<String, HalCapability>,
}

/// Exact match with Go `state.SignalView` (used by Cloud WS snapshot and USB API).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalView {
    pub available: bool,
    pub observed_at: Option<String>,
    pub rssi: Option<i32>,
    pub dbm: Option<i32>,
}

struct Inner {
    profile: String,
    snapshot: Snapshot,
    at_ok: bool,
    reason: String,
    observed: BTreeMap<String, Instant>,
    signal_rssi: Option<i32>,
    signal_observed_at: Option<String>,
}

pub struct StateStore {
    inner: RwLock<Inner>,
}

impl StateStore {
    pub fn new(module_id: String, boot_id: String, profile: String) -> Self {
        let mut fields = BTreeMap::new();
        for k in [
            "sim",
            "signal",
            "registration",
            "ims",
            "calls",
            "network",
            "platform",
        ] {
            fields.insert(k.to_string(), HalField::unavailable("", "initializing"));
        }
        Self {
            inner: RwLock::new(Inner {
                profile,
                snapshot: Snapshot {
                    schema_version: 1,
                    module_id,
                    agent_boot_id: boot_id,
                    revision: 0,
                    observed_at: now_rfc3339(),
                    freshness: "unavailable".into(),
                    scope: "read_only".into(),
                    voice_ready: false,
                    identity_state: "unenrolled".into(),
                    fields,
                },
                at_ok: false,
                reason: "initializing".into(),
                observed: BTreeMap::new(),
                signal_rssi: None,
                signal_observed_at: None,
            }),
        }
    }

    pub fn commit(&self, fields: BTreeMap<String, HalField>, at_ok: bool, reason: &str) {
        let mut g = self.inner.write().unwrap();
        let now_mono = Instant::now();
        g.snapshot.revision += 1;
        g.snapshot.observed_at = now_rfc3339();
        g.at_ok = at_ok;
        g.reason = reason.to_string();

        if let Some(sig) = fields.get("signal") {
            if sig.status == "available" {
                g.signal_observed_at = sig.observed_at.clone();
                g.signal_rssi = sig
                    .data
                    .as_ref()
                    .and_then(|d| d.get("rssi"))
                    .and_then(|v| v.as_i64())
                    .map(|v| v as i32);
            } else {
                g.signal_rssi = None;
                g.signal_observed_at = sig.observed_at.clone();
            }
        }
        for (k, f) in &fields {
            if f.observed_at.is_some() {
                g.observed.insert(k.clone(), now_mono);
            }
        }
        g.snapshot.fields = fields;
    }

    pub fn invalidate(&self, code: &str) {
        let mut g = self.inner.write().unwrap();
        g.at_ok = false;
        g.reason = code.to_string();
    }

    pub fn view(&self) -> (Snapshot, Ready) {
        let g = self.inner.read().unwrap();
        let now = Instant::now();
        let mut v = g.snapshot.clone();
        v.fields = BTreeMap::new();
        let mut r = Ready {
            ready: g.at_ok,
            scope: "read_only".into(),
            degraded: false,
            voice_ready: false,
            reasons: Vec::new(),
        };
        let mut add_reason = |code: &str| {
            if !code.is_empty() && !r.reasons.iter().any(|s| s == code) {
                r.reasons.push(code.to_string());
            }
        };
        if !g.at_ok {
            add_reason(&g.reason);
        }
        let mut stale = false;
        for (k, mut f) in g.snapshot.fields.clone() {
            let is_at_field = matches!(
                k.as_str(),
                "sim" | "signal" | "registration" | "ims" | "calls"
            );
            if !g.at_ok && is_at_field {
                f.status = "unavailable".into();
                f.error_code = Some(g.reason.clone());
                f.data = None;
            }
            if f.status == "available" {
                if let Some(obs) = g.observed.get(&k) {
                    if now.duration_since(*obs) > STALE_AFTER {
                        f.status = "unavailable".into();
                        f.error_code = Some("stale".into());
                        f.data = None;
                        stale = true;
                    }
                }
            }
            if f.status != "available" {
                r.degraded = true;
                if let Some(ec) = f.error_code.as_deref() {
                    add_reason(ec);
                }
                if matches!(k.as_str(), "sim" | "signal" | "registration" | "calls") {
                    r.ready = false;
                }
            }
            v.fields.insert(k, f);
        }
        for k in ["sim", "signal", "registration", "calls"] {
            if !v.fields.contains_key(k) {
                r.ready = false;
                r.degraded = true;
                add_reason("initializing");
            }
        }
        v.freshness = if stale {
            "stale".into()
        } else if !r.ready {
            "unavailable".into()
        } else {
            "fresh".into()
        };
        (v, r)
    }

    pub fn is_hardware_ready(&self) -> bool {
        self.view().1.ready
    }

    pub fn signal(&self) -> SignalView {
        let (v, _) = self.view();
        let g = self.inner.read().unwrap();
        let Some(f) = v.fields.get("signal") else {
            return SignalView::default();
        };
        let mut out = SignalView {
            available: false,
            observed_at: f.observed_at.clone(),
            rssi: None,
            dbm: None,
        };
        if f.status != "available" {
            return out;
        }
        if let Some(rssi) = g.signal_rssi {
            if (0..=31).contains(&rssi) {
                out.available = true;
                out.rssi = Some(rssi);
                out.dbm = Some(-113 + 2 * rssi);
            }
        }
        out
    }

    pub fn capabilities(&self, messaging_ready: bool, messaging_reason: &str) -> Capabilities {
        let (v, r) = self.view();
        let profile = self.inner.read().unwrap().profile.clone();
        let mut caps = BTreeMap::new();
        for (name, keys) in [
            ("telephony", &["calls"][..]),
            ("radio_sim", &["sim", "signal", "registration", "ims"][..]),
            ("network", &["network"][..]),
            ("platform", &["platform"][..]),
        ] {
            let mut c = HalCapability {
                support: "supported".into(),
                readiness: "ready".into(),
                reason: "".into(),
            };
            for k in keys {
                if let Some(f) = v.fields.get(*k) {
                    if f.status != "available" {
                        c.readiness = "unavailable".into();
                        c.reason = f.error_code.clone().unwrap_or_default();
                    }
                }
            }
            if name == "radio_sim" && r.ready && r.degraded {
                c.readiness = "degraded".into();
            }
            caps.insert(name.to_string(), c);
        }
        caps.insert(
            "messaging".into(),
            HalCapability {
                support: "supported".into(),
                readiness: if messaging_ready { "ready" } else { "unavailable" }.into(),
                reason: if messaging_ready {
                    "".into()
                } else {
                    messaging_reason.into()
                },
            },
        );
        caps.insert(
            "audio".into(),
            HalCapability {
                support: "supported".into(),
                readiness: "ready".into(),
                reason: "".into(),
            },
        );
        Capabilities {
            schema_version: 1,
            module_id: v.module_id,
            profile,
            capabilities: caps,
        }
    }
}
