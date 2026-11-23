//! Pure-Rust 3GPP TS 23.040 SMS-DELIVER decoder (GSM-7 + 8-bit + UCS-2 + UDH multi-part),
//! SMS-SUBMIT UCS-2 encoder (with TonUnknown for local/short numbers, TonInternational for `+`),
//! SHA-256 `eg25-sms-seen` deduplication ledger, full-store oldest-1/4 reaper, and SMS diagnostics.

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Mutex;
use time::{Date, Month, OffsetDateTime, PrimitiveDateTime, Time, UtcOffset};

use crate::journal::now_rfc3339;

#[derive(Debug, Clone)]
pub struct ReceivedSms {
    pub key: String,
    pub sender: String,
    pub text: String,
    pub indices: Vec<u16>,
    pub received_at: Option<OffsetDateTime>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageQuota {
    pub name: String,
    pub used: usize,
    pub total: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmsStorage {
    pub read: StorageQuota,
    pub write: StorageQuota,
    pub receive: StorageQuota,
}

/// Encode outgoing SMS-SUBMIT TPDU in UCS-2 (UTF-16BE) matching Go `eg25/sms.go`.
/// Returns `(tpdu_len, "00" + hex(tpdu))` ready for `AT+CMGS=<tpdu_len>` + payload.
/// - Numbers starting with `+` use `TON = International (0x91)`.
/// - All other numbers (including 5/6-digit short numbers like `10086`) use `TON = Unknown (0x81)`.
pub fn encode_submit_ucs2(number: &str, text: &str) -> Result<(usize, String), &'static str> {
    let utf16: Vec<u16> = text.encode_utf16().collect();
    if utf16.is_empty() || utf16.len() > 70 {
        return Err("sms_text_invalid");
    }
    let (toa, digits) = if let Some(rest) = number.strip_prefix('+') {
        (0x91u8, rest)
    } else {
        (0x81u8, number)
    };
    if digits.is_empty() || digits.len() > 20 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err("sms_number_invalid");
    }

    let mut tpdu = Vec::with_capacity(64 + utf16.len() * 2);
    tpdu.push(0x01); // First octet: SMS-SUBMIT (MTI=01, RD=0, VPF=00, SRR=0, UDHI=0, RP=0)
    tpdu.push(0x00); // TP-MR = 0
    tpdu.push(digits.len() as u8); // TP-DA length in digits
    tpdu.push(toa);
    // Semi-octet BCD swapped nibbles
    let dbytes = digits.as_bytes();
    let mut i = 0;
    while i < dbytes.len() {
        let lo = dbytes[i] - b'0';
        let hi = if i + 1 < dbytes.len() {
            dbytes[i + 1] - b'0'
        } else {
            0x0F
        };
        tpdu.push((hi << 4) | lo);
        i += 2;
    }
    tpdu.push(0x00); // TP-PID = 0
    tpdu.push(0x08); // TP-DCS = UCS-2 (16-bit)
    tpdu.push((utf16.len() * 2) as u8); // TP-UDL in octets
    for u in utf16 {
        tpdu.push((u >> 8) as u8);
        tpdu.push((u & 0xFF) as u8);
    }

    let tpdu_len = tpdu.len();
    let mut full = String::with_capacity(2 + tpdu_len * 2);
    full.push_str("00"); // Use SIM default SMSC
    full.push_str(&hex::encode(&tpdu));
    Ok((tpdu_len, full))
}

/// Parse `AT+CPMS?` response (`+CPMS: "ME",5,23,"ME",5,23,"ME",5,23`).
pub fn parse_cpms(lines: &[String]) -> Result<SmsStorage, &'static str> {
    let line = lines.first().ok_or("invalid_cpms")?;
    let rest = line.strip_prefix("+CPMS:").ok_or("invalid_cpms")?.trim();
    let fields: Vec<String> = split_csv_simple(rest);
    if fields.len() < 9 {
        return Err("invalid_cpms");
    }
    let parse_q = |idx: usize| -> Result<StorageQuota, &'static str> {
        Ok(StorageQuota {
            name: fields[idx].trim_matches('"').to_string(),
            used: fields[idx + 1].trim().parse().map_err(|_| "invalid_cpms")?,
            total: fields[idx + 2].trim().parse().map_err(|_| "invalid_cpms")?,
        })
    };
    Ok(SmsStorage {
        read: parse_q(0)?,
        write: parse_q(3)?,
        receive: parse_q(6)?,
    })
}

fn split_csv_simple(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    for ch in s.chars() {
        match ch {
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                out.push(cur.trim().to_string());
                cur.clear();
            }
            _ => cur.push(ch),
        }
    }
    out.push(cur.trim().to_string());
    out
}

#[derive(Debug, Clone)]
struct DeliverSegment {
    index: u16,
    raw_tpdu_hex: String,
    sender: String,
    received_at: Option<OffsetDateTime>,
    text: String,
    concat: Option<(u16, u8, u8)>, // (ref, total, seq 1-based)
}

/// Decode `AT+CMGL=4` lines into complete (reassembled multi-part) received SMS messages.
pub fn decode_cmgl(lines: &[String]) -> Result<Vec<ReceivedSms>, &'static str> {
    let mut out = Vec::new();
    let mut parts_map: HashMap<(String, u16, u8), BTreeMap<u8, DeliverSegment>> = HashMap::new();

    let mut i = 0usize;
    while i < lines.len() {
        if i + 1 >= lines.len() || !lines[i].starts_with("+CMGL:") {
            return Err("invalid_cmgl");
        }
        let header = lines[i].strip_prefix("+CMGL:").unwrap().trim();
        let fields = split_csv_simple(header);
        if fields.len() < 4 {
            return Err("invalid_cmgl");
        }
        let index: u16 = fields[0].parse().map_err(|_| "invalid_cmgl")?;
        let status: i32 = fields[1].parse().map_err(|_| "invalid_cmgl")?;
        let pdu_hex = lines[i + 1].trim();
        i += 2;

        // Only received unread (0) and received read (1).
        if status != 0 && status != 1 {
            continue;
        }
        let raw = hex::decode(pdu_hex).map_err(|_| "invalid_cmgl")?;
        if raw.len() < 2 {
            return Err("invalid_cmgl");
        }
        let smsc_len = raw[0] as usize;
        let offset = smsc_len + 1;
        if offset >= raw.len() {
            continue;
        }
        let tpdu = &raw[offset..];
        let Some(seg) = parse_deliver_tpdu(index, tpdu) else {
            continue;
        };

        if let Some((cref, total, seq)) = seg.concat {
            if total == 0 || seq == 0 || seq > total {
                continue;
            }
            let group_key = (seg.sender.clone(), cref, total);
            let group = parts_map.entry(group_key.clone()).or_default();
            group.entry(seq).or_insert(seg);
            if group.len() == total as usize {
                let completed = parts_map.remove(&group_key).unwrap();
                let mut key = String::new();
                let mut text = String::new();
                let mut indices = Vec::new();
                let mut sender = String::new();
                let mut received_at = None;
                for (pos, (_, p)) in completed.into_iter().enumerate() {
                    if pos == 0 {
                        sender = p.sender;
                        received_at = p.received_at;
                    }
                    key.push_str(&p.raw_tpdu_hex);
                    key.push(':');
                    text.push_str(&p.text);
                    indices.push(p.index);
                }
                out.push(ReceivedSms {
                    key,
                    sender,
                    text,
                    indices,
                    received_at,
                });
            }
        } else {
            let mut key = seg.raw_tpdu_hex;
            key.push(':');
            out.push(ReceivedSms {
                key,
                sender: seg.sender,
                text: seg.text,
                indices: vec![seg.index],
                received_at: seg.received_at,
            });
        }
    }
    Ok(out)
}

fn parse_deliver_tpdu(index: u16, tpdu: &[u8]) -> Option<DeliverSegment> {
    if tpdu.len() < 12 {
        return None;
    }
    let first = tpdu[0];
    // SMS-DELIVER has MTI bits [1:0] == 0b00
    if (first & 0x03) != 0x00 {
        return None;
    }
    let has_udhi = (first & 0x40) != 0;

    // Originating Address (TP-OA)
    let oa_len_digits = tpdu[1] as usize;
    let oa_type = tpdu[2];
    let oa_octets = (oa_len_digits + 1) / 2;
    let mut pos = 3 + oa_octets;
    if pos + 10 > tpdu.len() {
        return None;
    }
    let oa_bytes = &tpdu[3..3 + oa_octets];
    let sender = decode_address(oa_type, oa_len_digits, oa_bytes);

    let _pid = tpdu[pos];
    let dcs = tpdu[pos + 1];
    let scts = &tpdu[pos + 2..pos + 9];
    let received_at = decode_scts(scts);
    let udl = tpdu[pos + 9] as usize;
    pos += 10;
    let ud = &tpdu[pos..];

    let coding = decode_dcs(dcs);
    let mut concat = None;
    let mut udh_bytes = 0usize;

    if has_udhi {
        if ud.is_empty() {
            return None;
        }
        let udhl = ud[0] as usize;
        udh_bytes = 1 + udhl;
        if udh_bytes > ud.len() {
            return None;
        }
        let mut p = 1usize;
        while p + 2 <= udh_bytes {
            let iei = ud[p];
            let ielen = ud[p + 1] as usize;
            p += 2;
            if p + ielen > udh_bytes {
                break;
            }
            if iei == 0x00 && ielen == 3 {
                concat = Some((ud[p] as u16, ud[p + 1], ud[p + 2]));
            } else if iei == 0x08 && ielen == 4 {
                let r = u16::from_be_bytes([ud[p], ud[p + 1]]);
                concat = Some((r, ud[p + 2], ud[p + 3]));
            }
            p += ielen;
        }
    }

    let text = match coding {
        DcsKind::Gsm7 => {
            let skip_septets = if udh_bytes > 0 {
                (udh_bytes * 8 + 6) / 7
            } else {
                0
            };
            let total_septets = udl;
            let septets = unpack_gsm7(ud, total_septets);
            let slice = if skip_septets <= septets.len() {
                &septets[skip_septets..]
            } else {
                &[]
            };
            decode_gsm7_septets(slice)
        }
        DcsKind::EightBit => {
            let body = if udh_bytes <= ud.len() {
                let end = udl.min(ud.len());
                &ud[udh_bytes.min(end)..end]
            } else {
                &[]
            };
            String::from_utf8_lossy(body).to_string()
        }
        DcsKind::Ucs2 => {
            let end = udl.min(ud.len());
            let body = if udh_bytes <= end { &ud[udh_bytes..end] } else { &[] };
            let mut u16s = Vec::with_capacity(body.len() / 2);
            let mut k = 0;
            while k + 1 < body.len() {
                u16s.push(u16::from_be_bytes([body[k], body[k + 1]]));
                k += 2;
            }
            String::from_utf16_lossy(&u16s)
        }
    };

    Some(DeliverSegment {
        index,
        raw_tpdu_hex: hex::encode(tpdu),
        sender,
        received_at,
        text,
        concat,
    })
}

#[derive(Clone, Copy)]
enum DcsKind {
    Gsm7,
    EightBit,
    Ucs2,
}

fn decode_dcs(dcs: u8) -> DcsKind {
    if (dcs & 0xC0) == 0x00 {
        // General Data Coding group (00xx xxxx)
        match (dcs >> 2) & 0x03 {
            0 => DcsKind::Gsm7,
            1 => DcsKind::EightBit,
            2 => DcsKind::Ucs2,
            _ => DcsKind::Gsm7,
        }
    } else if (dcs & 0xF0) == 0xF0 {
        if (dcs & 0x04) != 0 {
            DcsKind::EightBit
        } else {
            DcsKind::Gsm7
        }
    } else if (dcs & 0xF0) == 0xE0 {
        DcsKind::Ucs2
    } else {
        DcsKind::Gsm7
    }
}

fn decode_address(toa: u8, len_digits: usize, bytes: &[u8]) -> String {
    let ton = (toa >> 4) & 0x07;
    if ton == 0x05 {
        // Alphanumeric (GSM-7 packed, len_digits is count of semi-octets)
        let septets = (len_digits * 4) / 7;
        return decode_gsm7_septets(&unpack_gsm7(bytes, septets));
    }
    let mut out = String::new();
    if ton == 0x01 {
        out.push('+');
    }
    for &b in bytes {
        let lo = b & 0x0F;
        let hi = (b >> 4) & 0x0F;
        for nib in [lo, hi] {
            if nib == 0x0F {
                break;
            }
            let ch = match nib {
                0..=9 => (b'0' + nib) as char,
                10 => '*',
                11 => '#',
                12 => 'a',
                13 => 'b',
                14 => 'c',
                _ => continue,
            };
            out.push(ch);
        }
    }
    out
}

fn bcd_swapped(b: u8) -> Option<u8> {
    let lo = b & 0x0F;
    let hi = (b >> 4) & 0x0F;
    if lo > 9 || hi > 9 {
        return None;
    }
    Some(lo * 10 + hi)
}

fn decode_scts(scts: &[u8]) -> Option<OffsetDateTime> {
    if scts.len() != 7 {
        return None;
    }
    let yy = bcd_swapped(scts[0])? as i32;
    let year = if yy >= 70 { 1900 + yy } else { 2000 + yy };
    let month = Month::try_from(bcd_swapped(scts[1])?).ok()?;
    let day = bcd_swapped(scts[2])?;
    let hour = bcd_swapped(scts[3])?;
    let min = bcd_swapped(scts[4])?;
    let sec = bcd_swapped(scts[5])?;
    let tz_byte = scts[6];
    let neg = (tz_byte & 0x08) != 0;
    let tz_lo = tz_byte & 0x07;
    let tz_hi = (tz_byte >> 4) & 0x0F;
    let quarters = (tz_lo as i32) * 10 + (tz_hi as i32);
    let offset_secs = quarters * 15 * 60 * if neg { -1 } else { 1 };
    let offset = UtcOffset::from_whole_seconds(offset_secs).ok()?;
    let date = Date::from_calendar_date(year, month, day).ok()?;
    let time = Time::from_hms(hour, min, sec).ok()?;
    Some(PrimitiveDateTime::new(date, time).assume_offset(offset))
}

fn unpack_gsm7(data: &[u8], count: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let bit_pos = i * 7;
        let byte_idx = bit_pos / 8;
        let bit_off = bit_pos % 8;
        if byte_idx >= data.len() {
            break;
        }
        let mut val = (data[byte_idx] >> bit_off) & 0x7F;
        if bit_off > 1 && byte_idx + 1 < data.len() {
            val |= (data[byte_idx + 1] << (8 - bit_off)) & 0x7F;
        }
        out.push(val);
    }
    out
}

fn decode_gsm7_septets(septets: &[u8]) -> String {
    const BASIC: [char; 128] = [
        '@', '£', '$', '¥', 'è', 'é', 'ù', 'ì', 'ò', 'Ç', '\n', 'Ø', 'ø', '\r', 'Å', 'å',
        'Δ', '_', 'Φ', 'Γ', 'Λ', 'Ω', 'Π', 'Ψ', 'Σ', 'Θ', 'Ξ', '\u{001B}', 'Æ', 'æ', 'ß', 'É',
        ' ', '!', '"', '#', '¤', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?',
        '¡', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
        'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'Ä', 'Ö', 'Ñ', 'Ü', '§',
        '¿', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
        'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'ä', 'ö', 'ñ', 'ü', 'à',
    ];
    let mut out = String::with_capacity(septets.len());
    let mut i = 0;
    while i < septets.len() {
        let c = septets[i];
        if c == 0x1B && i + 1 < septets.len() {
            i += 1;
            let ext = match septets[i] {
                0x0A => '\u{000C}',
                0x14 => '^',
                0x28 => '{',
                0x29 => '}',
                0x2F => '\\',
                0x3C => '[',
                0x3D => '~',
                0x3E => ']',
                0x40 => '|',
                0x65 => '€',
                other => BASIC[(other & 0x7F) as usize],
            };
            out.push(ext);
        } else {
            out.push(BASIC[(c & 0x7F) as usize]);
        }
        i += 1;
    }
    out
}

/// Persistent SHA-256 seen SMS ledger matching Go `eg25/ledger.go` (`state/eg25-sms-seen`).
pub struct SmsLedger {
    path: Option<PathBuf>,
    seen: HashSet<String>,
    initialized: bool,
}

impl SmsLedger {
    pub fn open(path: Option<PathBuf>) -> Self {
        let mut seen = HashSet::new();
        let mut initialized = false;
        if let Some(ref p) = path {
            if let Ok(text) = fs::read_to_string(p) {
                initialized = true;
                for line in text.lines() {
                    let h = line.trim();
                    if h.len() == 64 && hex::decode(h).is_ok() {
                        seen.insert(h.to_string());
                    }
                }
            }
        }
        Self {
            path,
            seen,
            initialized,
        }
    }

    fn key_hash(key: &str) -> String {
        let mut h = Sha256::new();
        h.update(key.as_bytes());
        hex::encode(h.finalize())
    }

    /// Reconciles currently stored keys against the seen ledger.
    /// First poll on a brand-new ledger seeds existing messages as already seen (so old SIM SMS
    /// aren't replayed on fresh install), while subsequent polls emit only newly arrived keys.
    pub fn reconcile(&mut self, keys: &[String]) -> Vec<String> {
        let mut fresh = Vec::new();
        let mut next_seen = HashSet::with_capacity(keys.len());
        for k in keys {
            let h = Self::key_hash(k);
            if self.initialized && !self.seen.contains(&h) {
                fresh.push(k.clone());
            }
            next_seen.insert(h);
        }
        self.initialized = true;
        if next_seen != self.seen {
            self.seen = next_seen;
            self.save();
        }
        fresh
    }

    fn save(&self) {
        let Some(ref p) = self.path else {
            return;
        };
        if let Some(parent) = p.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let mut sorted: Vec<&String> = self.seen.iter().collect();
        sorted.sort();
        let mut buf = String::new();
        for h in sorted {
            buf.push_str(h);
            buf.push('\n');
        }
        let tmp = p.with_extension("tmp");
        if let Ok(mut f) = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
        {
            if f.write_all(buf.as_bytes()).is_ok() && f.sync_all().is_ok() {
                let _ = fs::rename(&tmp, p);
            }
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SmsDiagnosticsSnapshot {
    pub poll_count: u64,
    pub last_poll_at: String,
    pub last_cmgl_records: usize,
    pub last_decoded_messages: usize,
    pub last_fresh_messages: usize,
    pub last_error: String,
    pub last_cleanup_error: String,
}

pub struct SmsDiagnostics {
    inner: Mutex<SmsDiagnosticsSnapshot>,
}

impl SmsDiagnostics {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(SmsDiagnosticsSnapshot::default()),
        }
    }

    pub fn record_poll(&self, records: usize, decoded: usize, fresh: usize, err: Option<&str>) {
        let mut g = self.inner.lock().unwrap();
        g.poll_count += 1;
        g.last_poll_at = now_rfc3339();
        g.last_cmgl_records = records;
        g.last_decoded_messages = decoded;
        g.last_fresh_messages = fresh;
        g.last_error = err.unwrap_or("").to_string();
    }

    pub fn record_cleanup_error(&self, err: Option<&str>) {
        let mut g = self.inner.lock().unwrap();
        g.last_cleanup_error = err.unwrap_or("").to_string();
    }

    pub fn snapshot(&self) -> SmsDiagnosticsSnapshot {
        self.inner.lock().unwrap().clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_short_number_with_ton_unknown_and_international_with_plus() {
        let (len_short, hex_short) = encode_submit_ucs2("10086", "你好").unwrap();
        assert!(hex_short.starts_with("0001000581")); // 05 digits, 81 = TonUnknown
        assert_eq!(hex_short.len(), 2 + len_short * 2);

        let (_len_intl, hex_intl) = encode_submit_ucs2("+8613800138000", "Hi").unwrap();
        assert!(hex_intl.starts_with("0001000d91")); // 13 digits, 91 = TonInternational
    }

    #[test]
    fn decodes_gsm7_and_ucs2_deliver_pdus() {
        // Minimal GSM-7 SMS-DELIVER: SMSC=00, First=04, OA=05 81 01 80 F6 (10086), PID=00, DCS=00,
        // SCTS=62113202000023 (2026-11-23 20:00:00 +0800), UDL=05, "Hello" = C8329BFD06
        let lines = vec![
            "+CMGL: 1,0,\"\",24".to_string(),
            "000405810180F600006211320200002305C8329BFD06".to_string(),
        ];
        let msgs = decode_cmgl(&lines).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].sender, "10086");
        assert_eq!(msgs[0].text, "Hello");
        assert_eq!(msgs[0].indices, vec![1]);
    }

    #[test]
    fn parses_cpms_storage() {
        let s = parse_cpms(&["+CPMS: \"ME\",23,23,\"ME\",23,23,\"ME\",23,23".to_string()]).unwrap();
        assert_eq!(s.read.name, "ME");
        assert_eq!(s.read.used, 23);
        assert_eq!(s.read.total, 23);
    }
}
