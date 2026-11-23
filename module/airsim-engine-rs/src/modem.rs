//! EG25 QDC507 (and RM500U AT) modem verification, hardware sampler, and telephony/SMS control loop.

use crate::at::{AtError, AtManager};
use crate::identity::uuid_v4;
use crate::sms_pdu::{
    decode_cmgl, encode_submit_ucs2, parse_cpms, ReceivedSms, SmsDiagnostics, SmsLedger,
};
use crate::state::{HalField, StateStore};
use serde_json::json;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

pub const EG25_PROFILE: &str = "eg25-qdc507";
pub const EG25_DEVICE: &str = "/dev/airsim_data11";
pub const RM500_PROFILE: &str = "rm500u-embedded";

pub const EMERGENCY_NUMBERS: &[&str] = &[
    "112", "911", "110", "119", "120", "122", "999", "000", "118",
];

pub fn supported_eg25_firmware(rev: &str) -> bool {
    let Some(rest) = rev.strip_prefix("QDC507GLEFM21_") else {
        return false;
    };
    let b = rest.as_bytes();
    if b.len() != 9 || b[2] != b'.' || b[6] != b'.' {
        return false;
    }
    [0, 1, 3, 4, 5, 7, 8].iter().all(|&i| b[i].is_ascii_digit())
}

pub fn verify_eg25_subversion_text(text: &str) -> bool {
    let mut project = "";
    let mut rev = "";
    for line in text.lines() {
        if let Some((k, v)) = line.split_once(':') {
            match k.trim() {
                "Project Name" => project = v.trim(),
                "Project Sub Rev" => rev = v.trim(),
                _ => {}
            }
        }
    }
    project == "EG25G_QDC507" && supported_eg25_firmware(rev)
}

pub fn verify_platform(profile: &str, at: &AtManager) -> Result<(), &'static str> {
    if profile == EG25_PROFILE {
        let sub = fs::read_to_string("/etc/quectel-project-subversion")
            .map_err(|_| "profile_mismatch")?;
        if !verify_eg25_subversion_text(&sub) {
            return Err("profile_mismatch");
        }
        let ati = at.query("ATI").map_err(|_| "query_failed")?;
        if !ati.iter().any(|l| l == "QDC507") {
            return Err("profile_mismatch");
        }
        let cgmr = at.query("AT+CGMR").map_err(|_| "query_failed")?;
        if !cgmr
            .iter()
            .any(|l| l == "QDC507GLEFM21" || supported_eg25_firmware(l))
        {
            return Err("profile_mismatch");
        }
    }
    Ok(())
}

fn split_csv(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_q = false;
    for ch in s.chars() {
        match ch {
            '"' => in_q = !in_q,
            ',' if !in_q => {
                out.push(cur.trim().to_string());
                cur.clear();
            }
            _ => cur.push(ch),
        }
    }
    out.push(cur.trim().to_string());
    out
}

fn sample_sim(at: &AtManager) -> HalField {
    match at.query("AT+CPIN?") {
        Ok(lines) if lines.len() == 1 => {
            if let Some(rest) = lines[0].strip_prefix("+CPIN:") {
                let s = rest.trim();
                if matches!(
                    s,
                    "READY"
                        | "SIM PIN"
                        | "SIM PUK"
                        | "PH-SIM PIN"
                        | "PH-FSIM PIN"
                        | "PH-FSIM PUK"
                        | "SIM PIN2"
                        | "SIM PUK2"
                        | "PH-NET PIN"
                        | "PH-NET PUK"
                        | "PH-NETSUB PIN"
                        | "PH-NETSUB PUK"
                        | "PH-SP PIN"
                        | "PH-SP PUK"
                        | "PH-CORP PIN"
                        | "PH-CORP PUK"
                ) {
                    return HalField::available("at", json!({"state": s}));
                }
            }
            HalField::unavailable("at", "invalid_response")
        }
        Ok(_) => HalField::unavailable("at", "invalid_response"),
        Err(AtError::Desynchronized) => HalField::unavailable("at", "at_desynchronized"),
        Err(_) => HalField::unavailable("at", "query_failed"),
    }
}

fn sample_signal(at: &AtManager) -> HalField {
    match at.query("AT+CSQ") {
        Ok(lines) if lines.len() == 1 => {
            if let Some(rest) = lines[0].strip_prefix("+CSQ:") {
                let p = split_csv(rest.trim());
                if p.len() == 2 {
                    if let (Ok(r), Ok(b)) = (p[0].parse::<i32>(), p[1].parse::<i32>()) {
                        if ((0..=31).contains(&r) || r == 99) && ((0..=7).contains(&b) || b == 99) {
                            let dbm = if r != 99 { Some(-113 + 2 * r) } else { None };
                            return HalField::available(
                                "at",
                                json!({"rssi": r, "ber": b, "dbm": dbm}),
                            );
                        }
                    }
                }
            }
            HalField::unavailable("at", "invalid_response")
        }
        Ok(_) => HalField::unavailable("at", "invalid_response"),
        Err(AtError::Desynchronized) => HalField::unavailable("at", "at_desynchronized"),
        Err(_) => HalField::unavailable("at", "query_failed"),
    }
}

fn parse_reg_stat(lines: &[String], prefix: &str) -> Option<i32> {
    if lines.len() != 1 {
        return None;
    }
    let rest = lines[0].strip_prefix(prefix)?;
    let p = split_csv(rest.trim());
    if p.len() < 2 {
        return None;
    }
    let mode: i32 = p[0].parse().ok()?;
    let stat: i32 = p[1].parse().ok()?;
    if (0..=5).contains(&mode) && (0..=10).contains(&stat) {
        Some(stat)
    } else {
        None
    }
}

fn sample_registration(at: &AtManager) -> HalField {
    let mut cs = None;
    let mut packet = None;
    let mut eps = None;
    let mut code = "query_failed";
    for (cmd, pfx, slot) in [
        ("AT+CREG?", "+CREG:", &mut cs),
        ("AT+CGREG?", "+CGREG:", &mut packet),
        ("AT+CEREG?", "+CEREG:", &mut eps),
    ] {
        match at.query(cmd) {
            Ok(ls) => {
                if let Some(n) = parse_reg_stat(&ls, pfx) {
                    *slot = Some(n);
                } else {
                    code = "invalid_response";
                }
            }
            Err(AtError::Desynchronized) => code = "at_desynchronized",
            Err(_) => {}
        }
    }
    if cs.is_none() && packet.is_none() && eps.is_none() {
        return HalField::unavailable("at", code);
    }
    HalField::available("at", json!({"cs": cs, "packet": packet, "eps": eps}))
}

#[derive(Debug, Clone)]
pub struct VoiceCall {
    pub object: String,
    pub index: i32,
    pub direction: i32,
    pub state: String,
    pub number: String,
}

pub fn parse_clcc_voice(lines: &[String]) -> Result<Vec<VoiceCall>, AtError> {
    const STATES: [&str; 7] = [
        "active",
        "held",
        "dialing",
        "alerting",
        "incoming",
        "waiting",
        "disconnected",
    ];
    let mut out = Vec::new();
    for line in lines {
        let rest = line
            .strip_prefix("+CLCC:")
            .ok_or(AtError::InvalidResponse)?;
        let p = split_csv(rest.trim());
        if p.len() < 5 {
            return Err(AtError::InvalidResponse);
        }
        let idx: i32 = p[0].parse().map_err(|_| AtError::InvalidResponse)?;
        let dir: i32 = p[1].parse().map_err(|_| AtError::InvalidResponse)?;
        let st: i32 = p[2].parse().map_err(|_| AtError::InvalidResponse)?;
        let mode: i32 = p[3].parse().map_err(|_| AtError::InvalidResponse)?;
        let _mpty: i32 = p[4].parse().map_err(|_| AtError::InvalidResponse)?;
        if mode != 0 {
            continue; // Voice calls only; ignore data/packet connections.
        }
        if !(1..=99).contains(&idx) || !(0..=1).contains(&dir) || !(0..=6).contains(&st) {
            return Err(AtError::InvalidResponse);
        }
        let state = STATES[st as usize];
        if state == "disconnected" {
            continue;
        }
        let number = p.get(5).cloned().unwrap_or_default();
        out.push(VoiceCall {
            object: String::new(),
            index: idx,
            direction: dir,
            state: state.to_string(),
            number,
        });
    }
    Ok(out)
}

fn sample_calls(at: &AtManager) -> HalField {
    match at.query("AT+CLCC") {
        Ok(lines) => match parse_clcc_voice(&lines) {
            Ok(calls) => {
                let states: Vec<i32> = calls
                    .iter()
                    .map(|c| match c.state.as_str() {
                        "active" => 0,
                        "held" => 1,
                        "dialing" => 2,
                        "alerting" => 3,
                        "incoming" => 4,
                        "waiting" => 5,
                        _ => 6,
                    })
                    .collect();
                HalField::available("at", json!({"count": states.len(), "states": states}))
            }
            Err(_) => HalField::unavailable("at", "invalid_response"),
        },
        Err(AtError::Desynchronized) => HalField::unavailable("at", "at_desynchronized"),
        Err(_) => HalField::unavailable("at", "query_failed"),
    }
}

fn sample_network() -> HalField {
    #[allow(unused_mut)]
    let mut ifaces: Vec<serde_json::Value> = Vec::new();
    #[cfg(target_os = "linux")]
    if let Ok(entries) = fs::read_dir("/sys/class/net") {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let flags = fs::read_to_string(e.path().join("flags"))
                .ok()
                .and_then(|s| u32::from_str_radix(s.trim().trim_start_matches("0x"), 16).ok())
                .unwrap_or(0);
            ifaces.push(json!({
                "name": name,
                "up": (flags & 1) != 0,
                "loopback": (flags & 8) != 0,
            }));
        }
    }
    HalField::available("linux", json!({"interfaces": ifaces}))
}

fn sample_platform() -> HalField {
    let mut mem_total = 0u64;
    let mut mem_avail = 0u64;
    if let Ok(text) = fs::read_to_string("/proc/meminfo") {
        for line in text.lines() {
            let mut it = line.split_whitespace();
            if let (Some(k), Some(v)) = (it.next(), it.next()) {
                if let Ok(n) = v.parse::<u64>() {
                    if k == "MemTotal:" {
                        mem_total = n;
                    } else if k == "MemAvailable:" {
                        mem_avail = n;
                    }
                }
            }
        }
    }
    let kernel = fs::read_to_string("/proc/sys/kernel/osrelease")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".into());
    HalField::available(
        "linux",
        json!({
            "os": std::env::consts::OS,
            "arch": match std::env::consts::ARCH { "arm" => "arm", "aarch64" => "arm64", x => x },
            "kernel": kernel,
            "mem_total_kb": mem_total,
            "mem_available_kb": mem_avail,
        }),
    )
}

pub fn sample_hardware(at: &AtManager, store: &StateStore) {
    let mut fields = BTreeMap::new();
    fields.insert("sim".into(), sample_sim(at));
    fields.insert("signal".into(), sample_signal(at));
    fields.insert("registration".into(), sample_registration(at));
    fields.insert("ims".into(), HalField::unavailable("at", "not_supported"));
    fields.insert("calls".into(), sample_calls(at));
    fields.insert("network".into(), sample_network());
    fields.insert("platform".into(), sample_platform());
    let at_ok = at.is_alive();
    let reason = if at_ok { "" } else { "at_desynchronized" };
    store.commit(fields, at_ok, reason);
}

pub fn failed_fields(reason: &str) -> BTreeMap<String, HalField> {
    let mut fields = BTreeMap::new();
    for k in ["sim", "signal", "registration", "ims", "calls"] {
        fields.insert(k.into(), HalField::unavailable("at", reason));
    }
    fields.insert("network".into(), sample_network());
    fields.insert("platform".into(), sample_platform());
    fields
}

#[derive(Debug, Clone)]
pub enum ModemEvent {
    CallAdd { object: String, state: String, number: String },
    CallState { object: String, state: String },
    CallNumber { object: String, number: String },
    CallRemove { object: String },
    MessageIncoming { sender: String, text: String },
    MessageAdd { object: String, state: String },
}

#[derive(Debug, Clone)]
pub struct WriteAction {
    pub action: String,
    pub object: String,
    pub number: String,
    pub tones: String,
    pub text: String,
}

#[derive(Debug, Clone, Default)]
pub struct WriteResult {
    pub object: String,
    pub failed: bool,
    pub unknown: bool,
}

pub struct ModemSession {
    pub epoch: String,
    at: Arc<AtManager>,
    calls: std::sync::Mutex<HashMap<i32, VoiceCall>>,
    sms_ledger: std::sync::Mutex<SmsLedger>,
    previous_sms: std::sync::Mutex<HashSet<String>>,
    diagnostics: Arc<SmsDiagnostics>,
    events_tx: mpsc::Sender<ModemEvent>,
}

impl ModemSession {
    pub fn connect(
        at: Arc<AtManager>,
        ledger_path: Option<std::path::PathBuf>,
        diagnostics: Arc<SmsDiagnostics>,
    ) -> Result<(Arc<Self>, mpsc::Receiver<ModemEvent>), &'static str> {
        at.command("ATE0", "").map_err(|_| "at_init_failed")?;
        at.command("AT+CMGF=0", "").map_err(|_| "at_init_failed")?;
        let epoch = uuid_v4().map_err(|_| "uuid_failed")?;
        let (tx, rx) = mpsc::channel(128);
        let sess = Arc::new(Self {
            epoch,
            at,
            calls: std::sync::Mutex::new(HashMap::new()),
            sms_ledger: std::sync::Mutex::new(SmsLedger::open(ledger_path)),
            previous_sms: std::sync::Mutex::new(HashSet::new()),
            diagnostics,
            events_tx: tx,
        });
        Ok((sess, rx))
    }

    pub fn initial_calls(&self) -> Result<Vec<VoiceCall>, AtError> {
        self.refresh_calls()?;
        Ok(self.calls.lock().unwrap().values().cloned().collect())
    }

    pub fn refresh_calls(&self) -> Result<bool, AtError> {
        let lines = self.at.query("AT+CLCC")?;
        let parsed = parse_clcc_voice(&lines)?;
        let mut guard = self.calls.lock().unwrap();
        let mut next = HashMap::new();
        for mut c in parsed {
            if let Some(old) = guard.get(&c.index) {
                c.object = old.object.clone();
                if c.state != old.state {
                    let _ = self.events_tx.try_send(ModemEvent::CallState {
                        object: c.object.clone(),
                        state: c.state.clone(),
                    });
                }
                if c.number != old.number {
                    let _ = self.events_tx.try_send(ModemEvent::CallNumber {
                        object: c.object.clone(),
                        number: c.number.clone(),
                    });
                }
            } else {
                c.object = uuid_v4().map_err(|_| AtError::QueryFailed)?;
                let _ = self.events_tx.try_send(ModemEvent::CallAdd {
                    object: c.object.clone(),
                    state: c.state.clone(),
                    number: c.number.clone(),
                });
            }
            next.insert(c.index, c);
        }
        for (idx, old) in guard.iter() {
            if !next.contains_key(idx) {
                let _ = self.events_tx.try_send(ModemEvent::CallRemove {
                    object: old.object.clone(),
                });
            }
        }
        let has_calls = !next.is_empty();
        *guard = next;
        Ok(has_calls)
    }

    pub fn refresh_sms(&self) -> Result<(), AtError> {
        let lines = match self.at.command("AT+CMGL=4", "") {
            Ok(l) => l,
            Err(e) => {
                self.diagnostics.record_poll(0, 0, 0, Some(&e.to_string()));
                return Err(e);
            }
        };
        let messages = match decode_cmgl(&lines) {
            Ok(m) => m,
            Err(e) => {
                self.diagnostics.record_poll(lines.len() / 2, 0, 0, Some(e));
                return Err(AtError::InvalidResponse);
            }
        };
        let keys: Vec<String> = messages.iter().map(|m| m.key.clone()).collect();
        let by_key: HashMap<&str, &ReceivedSms> =
            messages.iter().map(|m| (m.key.as_str(), m)).collect();
        let fresh = self.sms_ledger.lock().unwrap().reconcile(&keys);
        for k in &fresh {
            if let Some(m) = by_key.get(k.as_str()) {
                let _ = self.events_tx.try_send(ModemEvent::MessageIncoming {
                    sender: m.sender.clone(),
                    text: m.text.clone(),
                });
            }
        }
        self.diagnostics
            .record_poll(lines.len() / 2, messages.len(), fresh.len(), None);

        let cleanup_err = self.reclaim_sms_if_full(&messages).err();
        self.diagnostics.record_cleanup_error(cleanup_err);

        let mut prev = self.previous_sms.lock().unwrap();
        prev.clear();
        for k in keys {
            prev.insert(k);
        }
        Ok(())
    }

    fn reclaim_sms_if_full(&self, messages: &[ReceivedSms]) -> Result<usize, &'static str> {
        let prev = self.previous_sms.lock().unwrap().clone();
        let mut candidates: Vec<&ReceivedSms> = messages
            .iter()
            .filter(|m| prev.contains(&m.key) && !m.indices.is_empty() && m.received_at.is_some())
            .collect();
        if candidates.is_empty() {
            return Ok(0);
        }
        let cpms_lines = self.at.query("AT+CPMS?").map_err(|_| "cpms_query_failed")?;
        let storage = parse_cpms(&cpms_lines)?;
        if storage.read.used < storage.read.total || storage.read.total == 0 {
            return Ok(0);
        }
        if storage.read.name != storage.receive.name {
            return Err("storage_mismatch");
        }
        candidates.sort_by_key(|m| m.received_at);
        let target = (storage.read.total / 4).clamp(1, 8);
        let mut deleted = HashSet::new();
        for m in candidates {
            for &idx in &m.indices {
                if deleted.contains(&idx) {
                    continue;
                }
                self.at
                    .command(&format!("AT+CMGD={idx}"), "")
                    .map_err(|_| "cmgd_failed")?;
                deleted.insert(idx);
            }
            if deleted.len() >= target {
                break;
            }
        }
        if !deleted.is_empty() {
            eprintln!("eg25 sms storage reclaimed: records={}", deleted.len());
        }
        Ok(deleted.len())
    }

    pub fn execute(&self, a: &WriteAction) -> WriteResult {
        if a.action == "sms.send" {
            let Ok((tpdu_len, hex_payload)) = encode_submit_ucs2(&a.number, &a.text) else {
                return WriteResult { failed: true, ..Default::default() };
            };
            let Ok(obj) = uuid_v4() else {
                return WriteResult { failed: true, ..Default::default() };
            };
            match self.at.command(&format!("AT+CMGS={tpdu_len}"), &hex_payload) {
                Ok(lines) if lines.len() == 1 && lines[0].starts_with("+CMGS:") => {
                    let _ = self.events_tx.try_send(ModemEvent::MessageAdd {
                        object: obj.clone(),
                        state: "sent".into(),
                    });
                    return WriteResult { object: obj, ..Default::default() };
                }
                Ok(_) => return WriteResult { unknown: true, ..Default::default() },
                Err(AtError::QueryFailed | AtError::InvalidResponse) => {
                    return WriteResult { failed: true, ..Default::default() };
                }
                Err(_) => return WriteResult { unknown: true, ..Default::default() },
            }
        }

        if self.refresh_calls().is_err() {
            return WriteResult { failed: true, ..Default::default() };
        }
        let (call_count, target) = {
            let g = self.calls.lock().unwrap();
            let target = g.values().find(|c| c.object == a.object).cloned();
            (g.len(), target)
        };

        let cmd = match a.action.as_str() {
            "call.dial" => {
                if call_count != 0 {
                    return WriteResult { failed: true, ..Default::default() };
                }
                format!("ATD{};", a.number)
            }
            "call.answer" => {
                let Some(t) = target else {
                    return WriteResult { failed: true, ..Default::default() };
                };
                if t.state != "incoming" || call_count != 1 {
                    return WriteResult { failed: true, ..Default::default() };
                }
                "ATA".to_string()
            }
            "call.hangup" => {
                let Some(t) = target else {
                    return WriteResult { failed: true, ..Default::default() };
                };
                if call_count == 1 {
                    "AT+CHUP".to_string()
                } else if t.index <= 7 {
                    format!("AT+CHLD=1{}", t.index)
                } else {
                    "AT+CHUP".to_string()
                }
            }
            "call.dtmf" => {
                let Some(t) = target else {
                    return WriteResult { failed: true, ..Default::default() };
                };
                if t.state != "active" || call_count != 1 {
                    return WriteResult { failed: true, ..Default::default() };
                }
                let formatted = a
                    .tones
                    .chars()
                    .map(|c| format!("\"{c}\""))
                    .collect::<Vec<_>>()
                    .join(",");
                format!("AT+VTS={formatted}")
            }
            _ => return WriteResult { failed: true, ..Default::default() },
        };

        match self.at.command(&cmd, "") {
            Ok(_) => {
                let _ = self.refresh_calls();
                if a.action == "call.dial" {
                    let g = self.calls.lock().unwrap();
                    if let Some(c) = g.values().next() {
                        return WriteResult { object: c.object.clone(), ..Default::default() };
                    }
                }
                WriteResult::default()
            }
            Err(AtError::QueryFailed | AtError::InvalidResponse) => {
                WriteResult { failed: true, ..Default::default() }
            }
            Err(_) => WriteResult { unknown: true, ..Default::default() },
        }
    }

    /// Adaptive modem poll loop (1 s during call, 3 s idle calls, 15 s idle SMS, instant URC wake,
    /// 15 s transient CME 100 budget while ringing).
    pub async fn run_poll_loop(self: Arc<Self>, mut shutdown: tokio::sync::watch::Receiver<bool>) {
        let urc = self.at.urc_notify();
        let mut failing_since: Option<Instant> = None;
        let mut last_sms: Option<Instant> = None;
        let mut next_wait = Duration::from_secs(1);

        loop {
            let urc_wake = tokio::select! {
                _ = shutdown.changed() => return,
                _ = urc.notified() => true,
                _ = tokio::time::sleep(next_wait) => false,
            };
            if !self.at.is_alive() {
                return;
            }

            let sess = self.clone();
            let do_sms_if_idle = urc_wake
                || last_sms
                    .map(|t| t.elapsed() >= Duration::from_secs(15))
                    .unwrap_or(true);
            let res = tokio::task::spawn_blocking(move || {
                let has_calls = sess.refresh_calls()?;
                let mut sms_polled = false;
                if !has_calls && do_sms_if_idle {
                    sess.refresh_sms()?;
                    sms_polled = true;
                }
                Ok::<(bool, bool), AtError>((has_calls, sms_polled))
            })
            .await;

            match res {
                Ok(Ok((has_calls, sms_polled))) => {
                    failing_since = None;
                    if sms_polled {
                        last_sms = Some(Instant::now());
                    }
                    next_wait = if has_calls {
                        Duration::from_secs(1)
                    } else {
                        Duration::from_secs(3)
                    };
                }
                Ok(Err(AtError::QueryFailed)) => {
                    let start = *failing_since.get_or_insert_with(Instant::now);
                    if start.elapsed() >= Duration::from_secs(15) {
                        eprintln!("eg25 control poll stopped: query budget exceeded");
                        return;
                    }
                    next_wait = Duration::from_secs(1);
                }
                _ => {
                    eprintln!("eg25 control poll stopped: AT error");
                    return;
                }
            }
        }
    }
}
