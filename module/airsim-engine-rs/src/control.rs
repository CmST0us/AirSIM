//! Control coordinator: manages calls, SMS messages, command idempotency journal,
//! serialized call/SMS execution queues, 10s observation watch, emergency number blocking,
//! and audio qualification state.

use crate::identity::{is_valid_uuid_v4, uuid_v4, Identity};
use crate::journal::{now_rfc3339, parse_rfc3339, Record, Store as JournalStore};
use crate::modem::{ModemEvent, ModemSession, WriteAction, EMERGENCY_NUMBERS};
use crate::state::StateStore;
use crate::strict_json;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};

const MAX_CALL_HISTORY: usize = 64;
const MAX_MESSAGES: usize = 256;
const MAX_MESSAGE_BYTES: usize = 128 * 1024;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommandArgs {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub number: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub call_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub tones: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CommandRequest {
    pub command_id: String,
    pub agent_boot_id: String,
    pub backend_epoch: String,
    pub deadline: String,
    pub action: String,
    pub args: CommandArgs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseCommandError {
    InvalidParameters,
    UnsupportedAction,
}

impl CommandRequest {
    pub fn parse(data: &[u8]) -> Result<Self, ParseCommandError> {
        if data.len() > 4096 {
            return Err(ParseCommandError::InvalidParameters);
        }
        let obj = strict_json::parse_object(
            data,
            &[
                "command_id",
                "agent_boot_id",
                "backend_epoch",
                "deadline",
                "action",
                "args",
            ],
            &[],
        )
        .map_err(|_| ParseCommandError::InvalidParameters)?;

        let r: CommandRequest = serde_json::from_slice(data)
            .map_err(|_| ParseCommandError::InvalidParameters)?;

        if !is_valid_uuid_v4(&r.command_id)
            || !is_valid_uuid_v4(&r.agent_boot_id)
            || !is_valid_uuid_v4(&r.backend_epoch)
            || parse_rfc3339(&r.deadline).is_none()
        {
            return Err(ParseCommandError::InvalidParameters);
        }

        let req_keys: &[&str] = match r.action.as_str() {
            "call.dial" => &["number"],
            "call.answer" | "call.hangup" => &["call_id"],
            "call.dtmf" => &["call_id", "tones"],
            "sms.send" => &["number", "text"],
            _ => return Err(ParseCommandError::UnsupportedAction),
        };

        let args_bytes = serde_json::to_vec(obj.get("args").unwrap())
            .map_err(|_| ParseCommandError::InvalidParameters)?;
        strict_json::parse_object(&args_bytes, req_keys, &[])
            .map_err(|_| ParseCommandError::InvalidParameters)?;

        match r.action.as_str() {
            "call.dial" | "sms.send" => {
                if !is_valid_number(&r.args.number) {
                    return Err(ParseCommandError::InvalidParameters);
                }
            }
            _ => {}
        }
        if r.action == "sms.send" {
            let utf16_len = r.args.text.encode_utf16().count();
            if r.args.text.is_empty() || r.args.text.contains('\0') || utf16_len > 70 {
                return Err(ParseCommandError::InvalidParameters);
            }
        }
        if matches!(r.action.as_str(), "call.answer" | "call.hangup" | "call.dtmf")
            && !is_valid_uuid_v4(&r.args.call_id)
        {
            return Err(ParseCommandError::InvalidParameters);
        }
        if r.action == "call.dtmf" && !is_valid_tones(&r.args.tones) {
            return Err(ParseCommandError::InvalidParameters);
        }
        Ok(r)
    }

    pub fn canonical_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    pub fn budget(&self) -> Option<Instant> {
        let dl = parse_rfc3339(&self.deadline)?;
        let now = time::OffsetDateTime::now_utc();
        let diff = dl - now;
        if diff.is_negative() || diff.is_zero() || diff > time::Duration::seconds(60) {
            return None;
        }
        let dur = Duration::from_nanos(diff.whole_nanoseconds().max(0) as u64);
        Some(Instant::now() + dur)
    }
}

fn is_valid_number(s: &str) -> bool {
    let digits = s.strip_prefix('+').unwrap_or(s);
    (6..=15).contains(&digits.len()) && digits.bytes().all(|b| b.is_ascii_digit())
}

fn is_valid_tones(s: &str) -> bool {
    (1..=16).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'A'..=b'D' | b'*' | b'#'))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Call {
    pub call_id: String,
    pub state: String,
    pub ownership: String,
    pub direction: String,
    pub number: String,
    pub observed_at: String,
    pub disconnect_reason: String,
    #[serde(skip)]
    pub object: String,
    #[serde(skip)]
    pub epoch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Message {
    pub message_id: String,
    pub direction: String,
    pub sender: String,
    pub recipient: String,
    pub text: String,
    pub state: String,
    pub delivery: String,
    pub observed_at: String,
    #[serde(skip)]
    pub object: String,
    #[serde(skip)]
    pub epoch: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ControlStatus {
    pub schema_version: i32,
    pub agent_boot_id: String,
    pub backend_epoch: String,
    pub ready: bool,
    pub reason: String,
    pub scope: String,
    pub voice_ready: bool,
    pub telephony_ready: bool,
    pub messaging_ready: bool,
    pub inbox_gap: bool,
    pub inbox_dropped: u64,
    pub command_capacity_remaining: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CallsView {
    pub agent_boot_id: String,
    pub backend_epoch: String,
    pub available: bool,
    pub calls: Vec<Call>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MessagesView {
    pub agent_boot_id: String,
    pub backend_epoch: String,
    pub available: bool,
    pub inbox_gap: bool,
    pub inbox_dropped: u64,
    pub messages: Vec<Message>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Receipt {
    pub command_id: String,
    pub action: String,
    pub state: String,
    pub result_code: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub call_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub message_id: String,
    pub updated_at: String,
}

impl From<&Record> for Receipt {
    fn from(r: &Record) -> Self {
        Self {
            command_id: r.command_id.clone(),
            action: r.action.clone(),
            state: r.state.clone(),
            result_code: r.result_code.clone(),
            call_id: r.call_id.clone(),
            message_id: r.message_id.clone(),
            updated_at: r.updated_at.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioSessionView {
    pub session_id: String,
    pub call_id: String,
    pub agent_boot_id: String,
    pub backend_epoch: String,
    pub state: String,
    pub reason: String,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub closed_at: Option<String>,
    pub uplink_frames: u64,
    pub downlink_frames: u64,
    pub uplink_sequence_gaps: u64,
    pub downlink_sequence_gaps: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioView {
    pub available: bool,
    pub implementation: String,
    pub verification: String,
    pub voice_ready: bool,
    pub reason: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<AudioSessionView>,
}

#[derive(Debug, Clone)]
pub struct AudioQualification {
    pub eligible: bool,
    pub boot: String,
    pub epoch: String,
    pub call_id: String,
    pub generation: u64,
}

struct Observation {
    command_id: String,
    call_id: String,
    action: String,
    until: Instant,
}

pub struct PendingJob {
    request: CommandRequest,
    deadline: Instant,
    record: Record,
}

struct CoordinatorInner {
    boot: String,
    epoch: String,
    ready: bool,
    reason: String,
    session: Option<Arc<ModemSession>>,
    calls: HashMap<String, Call>,
    call_objects: HashMap<String, String>, // object_uuid -> call_id
    ended_order: Vec<String>,
    messages: Vec<Message>,
    message_bytes: usize,
    dial_reservation: String,
    watch: Vec<Observation>,
    inbox_gap: bool,
    inbox_dropped: u64,
    audio_gen: u64,
    active_audio: Option<AudioSessionView>,
}

pub struct Coordinator {
    identity: Identity,
    journal: Arc<JournalStore>,
    state: Arc<StateStore>,
    inner: Mutex<CoordinatorInner>,
    call_tx: mpsc::Sender<PendingJob>,
    sms_tx: mpsc::Sender<PendingJob>,
    audio_notify: Arc<tokio::sync::Notify>,
}

impl Coordinator {
    pub fn new(
        boot: String,
        identity: Identity,
        journal: Arc<JournalStore>,
        state: Arc<StateStore>,
    ) -> (Arc<Self>, mpsc::Receiver<PendingJob>, mpsc::Receiver<PendingJob>) {
        let (call_tx, call_rx) = mpsc::channel(8);
        let (sms_tx, sms_rx) = mpsc::channel(8);
        let coord = Arc::new(Self {
            identity,
            journal,
            state,
            inner: Mutex::new(CoordinatorInner {
                boot,
                epoch: String::new(),
                ready: false,
                reason: "initializing".into(),
                session: None,
                calls: HashMap::new(),
                call_objects: HashMap::new(),
                ended_order: Vec::new(),
                messages: Vec::new(),
                message_bytes: 0,
                dial_reservation: String::new(),
                watch: Vec::new(),
                inbox_gap: false,
                inbox_dropped: 0,
                audio_gen: 0,
                active_audio: None,
            }),
            call_tx,
            sms_tx,
            audio_notify: Arc::new(tokio::sync::Notify::new()),
        });
        (coord, call_rx, sms_rx)
    }

    pub fn boot_id(&self) -> String {
        self.inner.lock().unwrap().boot.clone()
    }

    pub fn audio_notify(&self) -> Arc<tokio::sync::Notify> {
        self.audio_notify.clone()
    }

    pub fn set_active_audio(&self, sess: Option<AudioSessionView>) {
        self.inner.lock().unwrap().active_audio = sess;
    }

    pub fn audio_view(&self) -> AudioView {
        let g = self.inner.lock().unwrap();
        let active_call = g
            .calls
            .values()
            .any(|c| c.epoch == g.epoch && c.state == "active");
        AudioView {
            available: g.ready && !self.journal.is_failed(),
            implementation: "rust-unified-rt-opus64-wsola".into(),
            verification: "verified".into(),
            voice_ready: g.ready && active_call,
            reason: if g.ready { "".into() } else { g.reason.clone() },
            session: g.active_audio.clone(),
        }
    }

    pub fn audio_qualification(&self) -> AudioQualification {
        let g = self.inner.lock().unwrap();
        let active: Vec<&Call> = g
            .calls
            .values()
            .filter(|c| c.epoch == g.epoch && c.state != "disconnected")
            .collect();
        let (eligible, call_id) = if g.ready && active.len() == 1 && active[0].state == "active" {
            (true, active[0].call_id.clone())
        } else {
            (false, String::new())
        };
        AudioQualification {
            eligible,
            boot: g.boot.clone(),
            epoch: g.epoch.clone(),
            call_id,
            generation: g.audio_gen,
        }
    }

    pub fn attach_session(&self, session: Arc<ModemSession>, initial_calls: Vec<crate::modem::VoiceCall>) {
        let mut g = self.inner.lock().unwrap();
        g.epoch = session.epoch.clone();
        g.session = Some(session);
        g.ready = true;
        g.reason.clear();
        g.calls.clear();
        g.call_objects.clear();
        g.ended_order.clear();
        g.dial_reservation.clear();
        let now = now_rfc3339();
        let epoch = g.epoch.clone();
        for vc in initial_calls {
            let cid = uuid_v4().unwrap_or_else(|_| vc.object.clone());
            let ownership = if vc.state == "incoming" || vc.state == "waiting" {
                "incoming"
            } else {
                "unmanaged"
            };
            let dir = if vc.direction == 1 { "incoming" } else { "outgoing" };
            g.call_objects.insert(vc.object.clone(), cid.clone());
            g.calls.insert(
                cid.clone(),
                Call {
                    call_id: cid,
                    state: vc.state,
                    ownership: ownership.into(),
                    direction: dir.into(),
                    number: vc.number,
                    observed_at: now.clone(),
                    disconnect_reason: String::new(),
                    object: vc.object,
                    epoch: epoch.clone(),
                },
            );
        }
        g.audio_gen += 1;
        drop(g);
        self.audio_notify.notify_waiters();
    }

    pub fn detach_session(&self, reason: &str) {
        let mut g = self.inner.lock().unwrap();
        g.ready = false;
        g.reason = reason.to_string();
        g.session = None;
        g.dial_reservation.clear();
        g.audio_gen += 1;
        drop(g);
        self.audio_notify.notify_waiters();
    }

    pub fn status(&self) -> ControlStatus {
        let hw = self.state.is_hardware_ready();
        let j_ok = !self.journal.is_failed();
        let g = self.inner.lock().unwrap();
        let ready = g.ready && j_ok && hw;
        let reason = if !j_ok {
            "journal_unavailable".into()
        } else if !hw {
            "hardware_unavailable".into()
        } else if !g.ready {
            g.reason.clone()
        } else {
            String::new()
        };
        let voice_ready = ready
            && g.calls
                .values()
                .any(|c| c.epoch == g.epoch && c.state == "active");
        ControlStatus {
            schema_version: 1,
            agent_boot_id: g.boot.clone(),
            backend_epoch: g.epoch.clone(),
            ready,
            reason,
            scope: "local_control".into(),
            voice_ready,
            telephony_ready: ready,
            messaging_ready: ready,
            inbox_gap: g.inbox_gap,
            inbox_dropped: g.inbox_dropped,
            command_capacity_remaining: self.journal.remaining(),
        }
    }

    pub fn calls_view(&self) -> CallsView {
        let g = self.inner.lock().unwrap();
        let mut calls: Vec<Call> = g.calls.values().cloned().collect();
        calls.sort_by(|a, b| a.call_id.cmp(&b.call_id));
        CallsView {
            agent_boot_id: g.boot.clone(),
            backend_epoch: g.epoch.clone(),
            available: g.ready,
            calls,
        }
    }

    pub fn messages_view(&self, cloud_only_current_epoch: bool) -> MessagesView {
        let g = self.inner.lock().unwrap();
        let mut gap = g.inbox_gap;
        let mut msgs = Vec::with_capacity(g.messages.len());
        for m in &g.messages {
            if cloud_only_current_epoch && m.epoch != g.epoch {
                gap = true;
                continue;
            }
            msgs.push(m.clone());
        }
        MessagesView {
            agent_boot_id: g.boot.clone(),
            backend_epoch: g.epoch.clone(),
            available: g.ready,
            inbox_gap: gap,
            inbox_dropped: g.inbox_dropped,
            messages: msgs,
        }
    }

    pub fn command_receipt(&self, command_id: &str) -> Option<Receipt> {
        self.journal.get(command_id).map(|r| Receipt::from(&r))
    }

    pub fn submit(&self, req: CommandRequest) -> (Option<Receipt>, u16) {
        let digest = self
            .identity
            .command_digest(&req.action, &req.canonical_bytes());

        if let Some(old) = self.journal.get(&req.command_id) {
            if old.request_digest != digest {
                return (None, 409);
            }
            return (Some(Receipt::from(&old)), 200);
        }
        if self.journal.is_failed() {
            return (None, 503);
        }
        let Some(deadline) = req.budget() else {
            return (None, 400);
        };

        let hw_ok = self.state.is_hardware_ready();
        {
            let g = self.inner.lock().unwrap();
            if !g.ready || g.session.is_none() {
                return (None, 503);
            }
            if req.agent_boot_id != g.boot || req.backend_epoch != g.epoch {
                return (None, 409);
            }
            if !hw_ok {
                let allow_hangup = req.action == "call.hangup"
                    && g.calls
                        .get(&req.args.call_id)
                        .is_some_and(|c| c.ownership == "managed");
                if !allow_hangup {
                    return (None, 503);
                }
            }
            if matches!(req.action.as_str(), "call.dial" | "sms.send") {
                let norm = req.args.number.trim_start_matches('+');
                if EMERGENCY_NUMBERS.iter().any(|&e| e == norm) {
                    return (None, 400);
                }
            }
            let active_count = g
                .calls
                .values()
                .filter(|c| c.epoch == g.epoch && c.state != "disconnected")
                .count();
            match req.action.as_str() {
                "call.dial" => {
                    if active_count != 0 || !g.dial_reservation.is_empty() {
                        return (None, 409);
                    }
                }
                "sms.send" => {}
                "call.answer" | "call.hangup" | "call.dtmf" => {
                    let Some(c) = g.calls.get(&req.args.call_id) else {
                        return (None, 409);
                    };
                    if c.epoch != g.epoch || c.state == "disconnected" || c.ownership == "unmanaged" {
                        return (None, 409);
                    }
                    match req.action.as_str() {
                        "call.answer" => {
                            if c.ownership != "incoming" || c.state != "incoming" || active_count != 1 {
                                return (None, 409);
                            }
                        }
                        "call.dtmf" => {
                            if c.ownership != "managed" || c.state != "active" || active_count != 1 {
                                return (None, 409);
                            }
                        }
                        "call.hangup" => {
                            if c.ownership == "incoming"
                                && c.state != "incoming"
                                && c.state != "waiting"
                            {
                                return (None, 409);
                            }
                        }
                        _ => {}
                    }
                }
                _ => return (None, 404),
            }
        }

        if self.journal.remaining() == 0 {
            return (None, 429);
        }

        let now = now_rfc3339();
        let rec = Record {
            command_id: req.command_id.clone(),
            request_digest: digest,
            action: req.action.clone(),
            state: "prepared".into(),
            result_code: String::new(),
            call_id: String::new(),
            message_id: String::new(),
            created_at: now.clone(),
            updated_at: now,
            agent_boot_id: req.agent_boot_id.clone(),
            backend_epoch: req.backend_epoch.clone(),
        };

        let tx = if req.action == "sms.send" {
            &self.sms_tx
        } else {
            &self.call_tx
        };
        if tx.capacity() == 0 {
            return (None, 429);
        }
        if let Err(e) = self.journal.put(rec.clone()) {
            return match e {
                crate::journal::JournalError::Full => (None, 429),
                crate::journal::JournalError::Conflict => (None, 409),
                crate::journal::JournalError::Unavailable => (None, 503),
            };
        }
        let receipt = Receipt::from(&rec);
        let job = PendingJob {
            request: req,
            deadline,
            record: rec,
        };
        if tx.try_send(job).is_err() {
            return (None, 429);
        }
        (Some(receipt), 202)
    }

    pub fn apply_modem_event(&self, ev: ModemEvent) {
        let mut notify_audio = false;
        let now = now_rfc3339();
        let mut observed_updates: Vec<(String, String)> = Vec::new();
        {
            let mut g = self.inner.lock().unwrap();
            let epoch = g.epoch.clone();
            match ev {
                ModemEvent::CallAdd { object, state, number } => {
                    let cid = if let Some(existing) = g.call_objects.get(&object) {
                        existing.clone()
                    } else {
                        let id = uuid_v4().unwrap_or_else(|_| object.clone());
                        g.call_objects.insert(object.clone(), id.clone());
                        id
                    };
                    let ownership = if !g.dial_reservation.is_empty() && state != "incoming" {
                        "managed"
                    } else if state == "incoming" || state == "waiting" {
                        "incoming"
                    } else {
                        "unmanaged"
                    };
                    let direction = if state == "incoming" || state == "waiting" {
                        "incoming"
                    } else {
                        "outgoing"
                    };
                    g.calls.insert(
                        cid.clone(),
                        Call {
                            call_id: cid.clone(),
                            state: state.clone(),
                            ownership: ownership.into(),
                            direction: direction.into(),
                            number,
                            observed_at: now.clone(),
                            disconnect_reason: String::new(),
                            object,
                            epoch,
                        },
                    );
                    if state == "active" {
                        g.audio_gen += 1;
                        notify_audio = true;
                    }
                }
                ModemEvent::CallState { object, state } => {
                    if let Some(cid) = g.call_objects.get(&object).cloned() {
                        if let Some(c) = g.calls.get_mut(&cid) {
                            let prev = c.state.clone();
                            c.state = state.clone();
                            c.observed_at = now.clone();
                            if state == "active" && prev != "active" {
                                c.ownership = "managed".into();
                                g.audio_gen += 1;
                                notify_audio = true;
                            } else if prev == "active" && state != "active" {
                                g.audio_gen += 1;
                                notify_audio = true;
                            }
                        }
                        if state == "active" {
                            g.watch.retain(|w| {
                                if w.call_id == cid && w.action == "call.answer" {
                                    observed_updates.push((w.command_id.clone(), cid.clone()));
                                    false
                                } else {
                                    true
                                }
                            });
                        }
                    }
                }
                ModemEvent::CallNumber { object, number } => {
                    if let Some(cid) = g.call_objects.get(&object).cloned() {
                        if let Some(c) = g.calls.get_mut(&cid) {
                            c.number = number;
                            c.observed_at = now.clone();
                        }
                    }
                }
                ModemEvent::CallRemove { object } => {
                    if let Some(cid) = g.call_objects.remove(&object) {
                        if let Some(c) = g.calls.get_mut(&cid) {
                            c.state = "disconnected".into();
                            c.observed_at = now.clone();
                            c.disconnect_reason = "ended".into();
                        }
                        g.ended_order.push(cid.clone());
                        while g.ended_order.len() > MAX_CALL_HISTORY {
                            let old = g.ended_order.remove(0);
                            g.calls.remove(&old);
                        }
                        g.audio_gen += 1;
                        notify_audio = true;
                        g.watch.retain(|w| {
                            if w.call_id == cid && w.action == "call.hangup" {
                                observed_updates.push((w.command_id.clone(), cid.clone()));
                                false
                            } else {
                                true
                            }
                        });
                    }
                }
                ModemEvent::MessageIncoming { sender, text } => {
                    let mid = uuid_v4().unwrap_or_else(|_| now.clone());
                    let msg_bytes = sender.len() + text.len() + 64;
                    let m = Message {
                        message_id: mid,
                        direction: "incoming".into(),
                        sender,
                        recipient: String::new(),
                        text,
                        state: "received".into(),
                        delivery: "delivered".into(),
                        observed_at: now.clone(),
                        object: String::new(),
                        epoch,
                    };
                    g.message_bytes += msg_bytes;
                    g.messages.push(m);
                    while g.messages.len() > MAX_MESSAGES || g.message_bytes > MAX_MESSAGE_BYTES {
                        if let Some(old) = g.messages.first() {
                            g.message_bytes =
                                g.message_bytes.saturating_sub(old.sender.len() + old.text.len() + 64);
                        }
                        g.messages.remove(0);
                        g.inbox_gap = true;
                        g.inbox_dropped += 1;
                    }
                }
                ModemEvent::MessageAdd { object, state } => {
                    let _ = (object, state);
                }
            }
        }

        for (cmd_id, call_id) in observed_updates {
            if let Some(mut rec) = self.journal.get(&cmd_id) {
                if rec.state == "accepted" {
                    rec.state = "observed".into();
                    rec.call_id = call_id;
                    rec.updated_at = now_rfc3339();
                    let _ = self.journal.put(rec);
                }
            }
        }

        if notify_audio {
            self.audio_notify.notify_waiters();
        }
    }

    pub async fn run_worker(
        self: Arc<Self>,
        mut rx: mpsc::Receiver<PendingJob>,
        mut shutdown: watch::Receiver<bool>,
    ) {
        loop {
            let job = tokio::select! {
                _ = shutdown.changed() => return,
                j = rx.recv() => match j {
                    Some(j) => j,
                    None => return,
                }
            };
            self.execute_job(job).await;
        }
    }

    async fn execute_job(&self, mut job: PendingJob) {
        if Instant::now() >= job.deadline {
            job.record.state = "expired".into();
            job.record.result_code = "deadline_exceeded".into();
            job.record.updated_at = now_rfc3339();
            let _ = self.journal.put(job.record);
            return;
        }

        let (session, write_action) = {
            let mut g = self.inner.lock().unwrap();
            let Some(sess) = g.session.clone() else {
                job.record.state = "failed".into();
                job.record.result_code = "backend_unavailable".into();
                job.record.updated_at = now_rfc3339();
                let _ = self.journal.put(job.record);
                return;
            };
            let object = if !job.request.args.call_id.is_empty() {
                g.calls
                    .get(&job.request.args.call_id)
                    .map(|c| c.object.clone())
                    .unwrap_or_default()
            } else {
                String::new()
            };
            if job.request.action == "call.dial" {
                g.dial_reservation = job.request.command_id.clone();
            }
            (
                sess,
                WriteAction {
                    action: job.request.action.clone(),
                    object,
                    number: job.request.args.number.clone(),
                    tones: job.request.args.tones.clone(),
                    text: job.request.args.text.clone(),
                },
            )
        };

        job.record.state = "dispatched".into();
        job.record.updated_at = now_rfc3339();
        if self.journal.put(job.record.clone()).is_err() {
            return;
        }

        let res = tokio::task::spawn_blocking(move || session.execute(&write_action))
            .await
            .unwrap_or(crate::modem::WriteResult {
                unknown: true,
                ..Default::default()
            });

        let now = now_rfc3339();
        if res.failed {
            job.record.state = "failed".into();
            job.record.result_code = "backend_rejected".into();
        } else if res.unknown {
            job.record.state = "outcome_unknown".into();
            job.record.result_code = "backend_indeterminate".into();
        } else {
            job.record.state = "accepted".into();
            job.record.result_code.clear();
            let mut g = self.inner.lock().unwrap();
            if job.request.action == "call.dial" {
                let cid = if !res.object.is_empty() {
                    if let Some(existing) = g.call_objects.get(&res.object).cloned() {
                        if let Some(c) = g.calls.get_mut(&existing) {
                            c.ownership = "managed".into();
                        }
                        existing
                    } else {
                        let id = uuid_v4().unwrap_or_else(|_| res.object.clone());
                        let ep = g.epoch.clone();
                        g.call_objects.insert(res.object.clone(), id.clone());
                        g.calls.insert(
                            id.clone(),
                            Call {
                                call_id: id.clone(),
                                state: "dialing".into(),
                                ownership: "managed".into(),
                                direction: "outgoing".into(),
                                number: job.request.args.number.clone(),
                                observed_at: now.clone(),
                                disconnect_reason: String::new(),
                                object: res.object.clone(),
                                epoch: ep,
                            },
                        );
                        id
                    }
                } else {
                    uuid_v4().unwrap_or_default()
                };
                job.record.call_id = cid;
            } else if matches!(
                job.request.action.as_str(),
                "call.answer" | "call.hangup" | "call.dtmf"
            ) {
                job.record.call_id = job.request.args.call_id.clone();
                if matches!(job.request.action.as_str(), "call.answer" | "call.hangup") {
                    g.watch.push(Observation {
                        command_id: job.request.command_id.clone(),
                        call_id: job.request.args.call_id.clone(),
                        action: job.request.action.clone(),
                        until: Instant::now() + Duration::from_secs(10),
                    });
                }
            } else if job.request.action == "sms.send" {
                let mid = if is_valid_uuid_v4(&res.object) {
                    res.object.clone()
                } else {
                    uuid_v4().unwrap_or_default()
                };
                job.record.message_id = mid.clone();
                let ep = g.epoch.clone();
                let m = Message {
                    message_id: mid,
                    direction: "outgoing".into(),
                    sender: String::new(),
                    recipient: job.request.args.number.clone(),
                    text: job.request.args.text.clone(),
                    state: "sent".into(),
                    delivery: "sent".into(),
                    observed_at: now.clone(),
                    object: res.object,
                    epoch: ep,
                };
                g.message_bytes += m.recipient.len() + m.text.len() + 64;
                g.messages.push(m);
            }
        }

        {
            let mut g = self.inner.lock().unwrap();
            if g.dial_reservation == job.request.command_id {
                g.dial_reservation.clear();
            }
            // Purge expired observation watchers
            let now_mono = Instant::now();
            g.watch.retain(|w| now_mono < w.until);
        }

        job.record.updated_at = now;
        let _ = self.journal.put(job.record);
    }
}
