//! Pure-Rust RFC 5766 / RFC 8656 TURN client supporting both UDP and TCP transports.
//!
//! Designed for real-time audio on EG25/RM500 cellular modules talking to AirSIM's
//! Pion TURN server (`service/airsim/internal/media/turn.go`):
//! - Long-term credential auth: key = MD5(username:realm:password), MESSAGE-INTEGRITY = HMAC-SHA1.
//! - Allocates UDP relay address (`XOR-RELAYED-ADDRESS`), installs permissions (`CreatePermission`)
//!   and binds 4-byte `ChannelData` channels (`0x4000..0x7FFF`) on first packet to each peer.
//! - Zero-overhead hot path once ChannelBind completes (4-byte ChannelData framing).

use hmac::{Hmac, Mac};
use md5::{Digest as _, Md5};
use sha1::Sha1;
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::unix::io::{AsRawFd, RawFd};
use std::time::{Duration, Instant};

type HmacSha1 = Hmac<Sha1>;

const MAGIC_COOKIE: u32 = 0x2112_A442;

// STUN/TURN message types
const MSG_ALLOCATE_REQ: u16 = 0x0003;
const MSG_ALLOCATE_OK: u16 = 0x0103;
const MSG_ALLOCATE_ERR: u16 = 0x0113;
const MSG_REFRESH_REQ: u16 = 0x0004;
const MSG_REFRESH_OK: u16 = 0x0104;
const MSG_REFRESH_ERR: u16 = 0x0114;
const MSG_SEND_IND: u16 = 0x0016;
const MSG_DATA_IND: u16 = 0x0017;
const MSG_CREATE_PERM_REQ: u16 = 0x0008;
const MSG_CREATE_PERM_OK: u16 = 0x0108;
const MSG_CREATE_PERM_ERR: u16 = 0x0118;
const MSG_CHANNEL_BIND_REQ: u16 = 0x0009;
const MSG_CHANNEL_BIND_OK: u16 = 0x0109;
const MSG_CHANNEL_BIND_ERR: u16 = 0x0119;

// STUN/TURN attribute types
const ATTR_USERNAME: u16 = 0x0006;
const ATTR_MESSAGE_INTEGRITY: u16 = 0x0008;
const ATTR_ERROR_CODE: u16 = 0x0009;
const ATTR_CHANNEL_NUMBER: u16 = 0x000C;
const ATTR_LIFETIME: u16 = 0x000D;
const ATTR_XOR_PEER_ADDRESS: u16 = 0x0012;
const ATTR_DATA: u16 = 0x0013;
const ATTR_REALM: u16 = 0x0014;
const ATTR_NONCE: u16 = 0x0015;
const ATTR_XOR_RELAYED_ADDRESS: u16 = 0x0016;
const ATTR_REQUESTED_TRANSPORT: u16 = 0x0019;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnTransport {
    Udp,
    Tcp,
}

#[derive(Debug, Clone)]
pub struct TurnEndpoint {
    pub host: String,
    pub port: u16,
    pub transport: TurnTransport,
    pub username: String,
    pub credential: String,
}

pub fn parse_turn_url(url: &str, username: &str, credential: &str) -> Option<TurnEndpoint> {
    let rest = url.strip_prefix("turn:")?;
    let (hostport, query) = match rest.split_once('?') {
        Some((hp, q)) => (hp, Some(q)),
        None => (rest, None),
    };
    let mut transport = TurnTransport::Udp;
    if let Some(q) = query {
        for pair in q.split('&') {
            if let Some((k, v)) = pair.split_once('=') {
                if k.eq_ignore_ascii_case("transport") {
                    if v.eq_ignore_ascii_case("tcp") {
                        transport = TurnTransport::Tcp;
                    } else if v.eq_ignore_ascii_case("udp") {
                        transport = TurnTransport::Udp;
                    } else {
                        return None;
                    }
                }
            }
        }
    }
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) => (h.to_string(), p.parse::<u16>().ok()?),
        None => (hostport.to_string(), 3478),
    };
    if host.is_empty() {
        return None;
    }
    Some(TurnEndpoint {
        host,
        port,
        transport,
        username: username.to_string(),
        credential: credential.to_string(),
    })
}

fn random_tx_id() -> [u8; 12] {
    let mut id = [0u8; 12];
    let _ = getrandom::getrandom(&mut id);
    id
}

fn compute_auth_key(username: &str, realm: &str, password: &str) -> [u8; 16] {
    let mut hasher = Md5::new();
    hasher.update(username.as_bytes());
    hasher.update(b":");
    hasher.update(realm.as_bytes());
    hasher.update(b":");
    hasher.update(password.as_bytes());
    hasher.finalize().into()
}

struct StunBuilder {
    buf: Vec<u8>,
}

impl StunBuilder {
    fn new(msg_type: u16, tx_id: [u8; 12]) -> Self {
        let mut buf = Vec::with_capacity(128);
        buf.extend_from_slice(&msg_type.to_be_bytes());
        buf.extend_from_slice(&0u16.to_be_bytes()); // placeholder length
        buf.extend_from_slice(&MAGIC_COOKIE.to_be_bytes());
        buf.extend_from_slice(&tx_id);
        Self { buf }
    }

    fn add_attr(&mut self, attr_type: u16, value: &[u8]) {
        self.buf.extend_from_slice(&attr_type.to_be_bytes());
        self.buf.extend_from_slice(&(value.len() as u16).to_be_bytes());
        self.buf.extend_from_slice(value);
        let pad = (4 - (value.len() % 4)) % 4;
        for _ in 0..pad {
            self.buf.push(0);
        }
    }

    fn add_xor_addr(&mut self, attr_type: u16, addr: SocketAddr) {
        match addr {
            SocketAddr::V4(v4) => {
                let mut val = [0u8; 8];
                val[0] = 0;
                val[1] = 0x01; // IPv4
                let xport = v4.port() ^ ((MAGIC_COOKIE >> 16) as u16);
                val[2..4].copy_from_slice(&xport.to_be_bytes());
                let xip = u32::from_be_bytes(v4.ip().octets()) ^ MAGIC_COOKIE;
                val[4..8].copy_from_slice(&xip.to_be_bytes());
                self.add_attr(attr_type, &val);
            }
            SocketAddr::V6(_) => {
                // AirSIM TURN operates over IPv4.
            }
        }
    }

    fn finish_unauthenticated(mut self) -> Vec<u8> {
        let len = (self.buf.len() - 20) as u16;
        self.buf[2..4].copy_from_slice(&len.to_be_bytes());
        self.buf
    }

    fn finish_authenticated(mut self, username: &str, realm: &str, nonce: &str, key: &[u8; 16]) -> Vec<u8> {
        self.add_attr(ATTR_USERNAME, username.as_bytes());
        self.add_attr(ATTR_REALM, realm.as_bytes());
        self.add_attr(ATTR_NONCE, nonce.as_bytes());
        // RFC 5389 §15.4: length field includes the 24-byte MESSAGE-INTEGRITY attribute itself.
        let len_with_mi = (self.buf.len() - 20 + 24) as u16;
        self.buf[2..4].copy_from_slice(&len_with_mi.to_be_bytes());
        let mut mac = HmacSha1::new_from_slice(key).expect("hmac key");
        mac.update(&self.buf);
        let digest = mac.finalize().into_bytes();
        self.add_attr(ATTR_MESSAGE_INTEGRITY, &digest);
        self.buf
    }
}

struct ParsedStun<'a> {
    msg_type: u16,
    tx_id: [u8; 12],
    attrs: Vec<(u16, &'a [u8])>,
}

fn parse_stun(data: &[u8]) -> Option<ParsedStun<'_>> {
    if data.len() < 20 {
        return None;
    }
    if (data[0] & 0xC0) != 0 {
        return None;
    }
    let msg_type = u16::from_be_bytes([data[0], data[1]]);
    let msg_len = u16::from_be_bytes([data[2], data[3]]) as usize;
    let cookie = u32::from_be_bytes([data[4], data[5], data[6], data[7]]);
    if cookie != MAGIC_COOKIE || 20 + msg_len > data.len() {
        return None;
    }
    let mut tx_id = [0u8; 12];
    tx_id.copy_from_slice(&data[8..20]);
    let mut attrs = Vec::new();
    let mut off = 20usize;
    let end = 20 + msg_len;
    while off + 4 <= end {
        let atype = u16::from_be_bytes([data[off], data[off + 1]]);
        let alen = u16::from_be_bytes([data[off + 2], data[off + 3]]) as usize;
        off += 4;
        if off + alen > end {
            return None;
        }
        attrs.push((atype, &data[off..off + alen]));
        let pad = (4 - (alen % 4)) % 4;
        off = (off + alen + pad).min(end);
    }
    Some(ParsedStun {
        msg_type,
        tx_id,
        attrs,
    })
}

fn parse_xor_addr(val: &[u8]) -> Option<SocketAddr> {
    if val.len() < 8 || val[1] != 0x01 {
        return None;
    }
    let xport = u16::from_be_bytes([val[2], val[3]]);
    let port = xport ^ ((MAGIC_COOKIE >> 16) as u16);
    let xip = u32::from_be_bytes([val[4], val[5], val[6], val[7]]);
    let ip = Ipv4Addr::from(xip ^ MAGIC_COOKIE);
    Some(SocketAddr::new(IpAddr::V4(ip), port))
}

fn parse_error_code(val: &[u8]) -> Option<u16> {
    if val.len() < 4 {
        return None;
    }
    let class = (val[2] & 0x07) as u16;
    let number = val[3] as u16;
    Some(class * 100 + number)
}

enum TurnSocket {
    Udp(UdpSocket),
    Tcp {
        stream: TcpStream,
        rx_buf: Vec<u8>,
    },
}

struct PeerChannel {
    channel: u16,
    bound: bool,
    last_refresh: Instant,
    last_req: Instant,
}

pub struct TurnClient {
    sock: TurnSocket,
    server_addr: SocketAddr,
    local_addr: SocketAddr,
    relayed_addr: SocketAddr,
    username: String,
    realm: String,
    nonce: String,
    auth_key: [u8; 16],
    lifetime_secs: u32,
    last_refresh: Instant,
    next_channel: u16,
    peers: HashMap<SocketAddr, PeerChannel>,
    chan_to_peer: HashMap<u16, SocketAddr>,
    pending_binds: HashMap<[u8; 12], (SocketAddr, u16)>,
}

impl TurnClient {
    /// Connects to a TURN server and synchronously performs the 2-step Allocate handshake
    /// within `timeout`. Returns a non-blocking `TurnClient` ready for the `poll()` loop.
    pub fn allocate(ep: &TurnEndpoint, timeout: Duration) -> Result<Self, String> {
        let deadline = Instant::now() + timeout;
        let server_addr = format!("{}:{}", ep.host, ep.port)
            .to_socket_addrs()
            .map_err(|e| format!("turn_dns: {e}"))?
            .find(|a| a.is_ipv4())
            .ok_or_else(|| "turn_no_ipv4".to_string())?;

        let mut sock = match ep.transport {
            TurnTransport::Udp => {
                let u = UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("turn_udp_bind: {e}"))?;
                u.connect(server_addr).map_err(|e| format!("turn_udp_conn: {e}"))?;
                TurnSocket::Udp(u)
            }
            TurnTransport::Tcp => {
                let rem = deadline.saturating_duration_since(Instant::now());
                let s = TcpStream::connect_timeout(&server_addr, rem)
                    .map_err(|e| format!("turn_tcp_conn: {e}"))?;
                let _ = s.set_nodelay(true);
                TurnSocket::Tcp {
                    stream: s,
                    rx_buf: Vec::with_capacity(4096),
                }
            }
        };

        let local_addr = match &sock {
            TurnSocket::Udp(u) => u.local_addr().map_err(|e| e.to_string())?,
            TurnSocket::Tcp { stream, .. } => stream.local_addr().map_err(|e| e.to_string())?,
        };

        // Step 1: Unauthenticated Allocate request -> expect 401 with REALM + NONCE
        let tx1 = random_tx_id();
        let mut b1 = StunBuilder::new(MSG_ALLOCATE_REQ, tx1);
        b1.add_attr(ATTR_REQUESTED_TRANSPORT, &[17, 0, 0, 0]); // UDP
        let pkt1 = b1.finish_unauthenticated();

        let (realm, nonce) = Self::exchange_for_challenge(&mut sock, &pkt1, tx1, deadline)?;
        let auth_key = compute_auth_key(&ep.username, &realm, &ep.credential);

        // Step 2: Authenticated Allocate request -> expect 200 OK with XOR-RELAYED-ADDRESS
        let tx2 = random_tx_id();
        let mut b2 = StunBuilder::new(MSG_ALLOCATE_REQ, tx2);
        b2.add_attr(ATTR_REQUESTED_TRANSPORT, &[17, 0, 0, 0]);
        let pkt2 = b2.finish_authenticated(&ep.username, &realm, &nonce, &auth_key);

        let (relayed_addr, lifetime_secs) =
            Self::exchange_for_allocate(&mut sock, &pkt2, tx2, deadline)?;

        // Switch socket to non-blocking for the real-time `poll()` event loop!
        match &sock {
            TurnSocket::Udp(u) => {
                u.set_read_timeout(None).ok();
                u.set_nonblocking(true).map_err(|e| e.to_string())?;
            }
            TurnSocket::Tcp { stream, .. } => {
                stream.set_read_timeout(None).ok();
                stream.set_nonblocking(true).map_err(|e| e.to_string())?;
            }
        }

        Ok(Self {
            sock,
            server_addr,
            local_addr,
            relayed_addr,
            username: ep.username.clone(),
            realm,
            nonce,
            auth_key,
            lifetime_secs: lifetime_secs.clamp(60, 3600),
            last_refresh: Instant::now(),
            next_channel: 0x4000,
            peers: HashMap::new(),
            chan_to_peer: HashMap::new(),
            pending_binds: HashMap::new(),
        })
    }

    fn blocking_send_recv_stun(
        sock: &mut TurnSocket,
        req: &[u8],
        expected_tx: [u8; 12],
        deadline: Instant,
    ) -> Result<Vec<u8>, String> {
        let mut rto = Duration::from_millis(250);
        let mut last_send = Instant::now() - rto;
        let mut buf = [0u8; 2048];
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err("turn_timeout".into());
            }
            let rem = deadline - now;
            if now.duration_since(last_send) >= rto {
                match sock {
                    TurnSocket::Udp(u) => {
                        u.send(req).map_err(|e| format!("turn_send: {e}"))?;
                    }
                    TurnSocket::Tcp { stream, .. } => {
                        if last_send.elapsed() >= Duration::from_secs(60) || rto == Duration::from_millis(250) {
                            stream.write_all(req).map_err(|e| format!("turn_tcp_send: {e}"))?;
                        }
                    }
                }
                last_send = now;
                rto = (rto * 2).min(Duration::from_secs(2));
            }

            let wait = rem.min(Duration::from_millis(250));
            match sock {
                TurnSocket::Udp(u) => {
                    u.set_read_timeout(Some(wait)).ok();
                    match u.recv(&mut buf) {
                        Ok(n) => {
                            if let Some(p) = parse_stun(&buf[..n]) {
                                if p.tx_id == expected_tx {
                                    return Ok(buf[..n].to_vec());
                                }
                            }
                        }
                        Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
                        Err(e) => return Err(format!("turn_recv: {e}")),
                    }
                }
                TurnSocket::Tcp { stream, rx_buf } => {
                    stream.set_read_timeout(Some(wait)).ok();
                    match stream.read(&mut buf) {
                        Ok(0) => return Err("turn_tcp_eof".into()),
                        Ok(n) => {
                            rx_buf.extend_from_slice(&buf[..n]);
                            while let Some(frame) = pop_tcp_frame(rx_buf) {
                                if let Some(p) = parse_stun(&frame) {
                                    if p.tx_id == expected_tx {
                                        return Ok(frame);
                                    }
                                }
                            }
                        }
                        Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
                        Err(e) => return Err(format!("turn_tcp_recv: {e}")),
                    }
                }
            }
        }
    }

    fn exchange_for_challenge(
        sock: &mut TurnSocket,
        req: &[u8],
        tx: [u8; 12],
        deadline: Instant,
    ) -> Result<(String, String), String> {
        let resp = Self::blocking_send_recv_stun(sock, req, tx, deadline)?;
        let parsed = parse_stun(&resp).ok_or_else(|| "turn_bad_challenge".to_string())?;
        if parsed.msg_type != MSG_ALLOCATE_ERR {
            return Err(format!("turn_unexpected_type_{:04x}", parsed.msg_type));
        }
        let mut realm = None;
        let mut nonce = None;
        let mut code = None;
        for (t, v) in parsed.attrs {
            match t {
                ATTR_REALM => realm = std::str::from_utf8(v).ok().map(|s| s.to_string()),
                ATTR_NONCE => nonce = std::str::from_utf8(v).ok().map(|s| s.to_string()),
                ATTR_ERROR_CODE => code = parse_error_code(v),
                _ => {}
            }
        }
        if code != Some(401) {
            return Err(format!("turn_challenge_error_{:?}", code));
        }
        match (realm, nonce) {
            (Some(r), Some(n)) => Ok((r, n)),
            _ => Err("turn_missing_realm_nonce".into()),
        }
    }

    fn exchange_for_allocate(
        sock: &mut TurnSocket,
        req: &[u8],
        tx: [u8; 12],
        deadline: Instant,
    ) -> Result<(SocketAddr, u32), String> {
        let resp = Self::blocking_send_recv_stun(sock, req, tx, deadline)?;
        let parsed = parse_stun(&resp).ok_or_else(|| "turn_bad_alloc_resp".to_string())?;
        if parsed.msg_type != MSG_ALLOCATE_OK {
            return Err(format!("turn_alloc_rejected_{:04x}", parsed.msg_type));
        }
        let mut relayed = None;
        let mut lifetime = 600u32;
        for (t, v) in parsed.attrs {
            match t {
                ATTR_XOR_RELAYED_ADDRESS => relayed = parse_xor_addr(v),
                ATTR_LIFETIME if v.len() == 4 => {
                    lifetime = u32::from_be_bytes([v[0], v[1], v[2], v[3]]);
                }
                _ => {}
            }
        }
        relayed
            .map(|r| (r, lifetime))
            .ok_or_else(|| "turn_missing_relayed_addr".to_string())
    }

    pub fn raw_fd(&self) -> RawFd {
        match &self.sock {
            TurnSocket::Udp(u) => u.as_raw_fd(),
            TurnSocket::Tcp { stream, .. } => stream.as_raw_fd(),
        }
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn relayed_addr(&self) -> SocketAddr {
        self.relayed_addr
    }

    pub fn server_addr(&self) -> SocketAddr {
        self.server_addr
    }

    pub fn is_tcp(&self) -> bool {
        matches!(self.sock, TurnSocket::Tcp { .. })
    }

    fn send_raw(&mut self, bytes: &[u8]) -> io::Result<()> {
        match &mut self.sock {
            TurnSocket::Udp(u) => {
                let _ = u.send(bytes)?;
                Ok(())
            }
            TurnSocket::Tcp { stream, .. } => {
                // Non-blocking best-effort write for padded STUN/ChannelData frames.
                let mut written = 0;
                while written < bytes.len() {
                    match stream.write(&bytes[written..]) {
                        Ok(0) => return Err(io::Error::new(io::ErrorKind::WriteZero, "tcp_eof")),
                        Ok(n) => written += n,
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                            // Brief poll wait (up to 5 ms) to avoid splitting a TCP TURN frame mid-header.
                            let mut pfd = libc::pollfd {
                                fd: stream.as_raw_fd(),
                                events: libc::POLLOUT,
                                revents: 0,
                            };
                            let r = unsafe { libc::poll(&mut pfd, 1, 5) };
                            if r <= 0 {
                                return Err(e);
                            }
                        }
                        Err(e) => return Err(e),
                    }
                }
                Ok(())
            }
        }
    }

    /// Ensure permission + channel bind exists for `peer`, and transmit `payload` to `peer`.
    pub fn send_to_peer(&mut self, peer: SocketAddr, payload: &[u8]) -> io::Result<()> {
        let now = Instant::now();
        let need_bind = match self.peers.get(&peer) {
            None => true,
            Some(entry) => {
                (!entry.bound && now.duration_since(entry.last_req) > Duration::from_millis(400))
                    || (entry.bound && now.duration_since(entry.last_refresh) > Duration::from_secs(240))
            }
        };

        if need_bind {
            let chan = if let Some(entry) = self.peers.get_mut(&peer) {
                entry.last_req = now;
                entry.channel
            } else {
                let ch = self.next_channel;
                self.next_channel = if self.next_channel >= 0x7FFE {
                    0x4000
                } else {
                    self.next_channel + 1
                };
                self.peers.insert(
                    peer,
                    PeerChannel {
                        channel: ch,
                        bound: false,
                        last_refresh: now,
                        last_req: now,
                    },
                );
                self.chan_to_peer.insert(ch, peer);
                ch
            };

            // Send CreatePermission + ChannelBind (ChannelBind implies permission per RFC 5766 §11.1,
            // and sending both ensures immediate compatibility with every TURN server).
            let tx_p = random_tx_id();
            let mut bp = StunBuilder::new(MSG_CREATE_PERM_REQ, tx_p);
            bp.add_xor_addr(ATTR_XOR_PEER_ADDRESS, peer);
            let perm_msg = bp.finish_authenticated(&self.username, &self.realm, &self.nonce, &self.auth_key);
            let _ = self.send_raw(&perm_msg);

            let tx_b = random_tx_id();
            let mut bb = StunBuilder::new(MSG_CHANNEL_BIND_REQ, tx_b);
            bb.add_attr(ATTR_CHANNEL_NUMBER, &[ (chan >> 8) as u8, (chan & 0xff) as u8, 0, 0 ]);
            bb.add_xor_addr(ATTR_XOR_PEER_ADDRESS, peer);
            let bind_msg = bb.finish_authenticated(&self.username, &self.realm, &self.nonce, &self.auth_key);
            self.pending_binds.insert(tx_b, (peer, chan));
            let _ = self.send_raw(&bind_msg);
        }

        if let Some(entry) = self.peers.get(&peer) {
            if entry.bound {
                // Fast path: 4-byte RFC 5766 ChannelData framing!
                let mut frame = Vec::with_capacity(4 + payload.len() + 3);
                frame.extend_from_slice(&entry.channel.to_be_bytes());
                frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
                frame.extend_from_slice(payload);
                if self.is_tcp() {
                    let pad = (4 - (payload.len() % 4)) % 4;
                    for _ in 0..pad {
                        frame.push(0);
                    }
                }
                return self.send_raw(&frame);
            }
        }

        // Before ChannelBind OK arrives, send via RFC 5766 Send Indication.
        let mut bi = StunBuilder::new(MSG_SEND_IND, random_tx_id());
        bi.add_xor_addr(ATTR_XOR_PEER_ADDRESS, peer);
        bi.add_attr(ATTR_DATA, payload);
        let ind = bi.finish_unauthenticated();
        self.send_raw(&ind)
    }

    /// Periodic maintenance: refresh TURN allocation before expiry.
    pub fn handle_timeout(&mut self, now: Instant) {
        let refresh_every = Duration::from_secs((self.lifetime_secs / 2).max(30) as u64);
        if now.duration_since(self.last_refresh) >= refresh_every {
            self.last_refresh = now;
            let mut br = StunBuilder::new(MSG_REFRESH_REQ, random_tx_id());
            br.add_attr(ATTR_LIFETIME, &self.lifetime_secs.to_be_bytes());
            let msg = br.finish_authenticated(&self.username, &self.realm, &self.nonce, &self.auth_key);
            let _ = self.send_raw(&msg);
        }
    }

    /// Drain all currently readable datagrams from the TURN socket, unwrapping
    /// ChannelData and Data Indications into `(peer_addr, payload)` pairs.
    pub fn recv_packets(&mut self, out: &mut Vec<(SocketAddr, Vec<u8>)>) -> io::Result<()> {
        let mut raw_frames: Vec<Vec<u8>> = Vec::new();
        let mut buf = [0u8; 2048];
        match &mut self.sock {
            TurnSocket::Udp(u) => loop {
                match u.recv(&mut buf) {
                    Ok(n) => raw_frames.push(buf[..n].to_vec()),
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::Interrupted
                                | io::ErrorKind::ConnectionRefused
                                | io::ErrorKind::ConnectionReset
                        ) =>
                    {
                        continue;
                    }
                    Err(e) => return Err(e),
                }
            },
            TurnSocket::Tcp { stream, rx_buf } => loop {
                match stream.read(&mut buf) {
                    Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "turn_tcp_eof")),
                    Ok(n) => {
                        rx_buf.extend_from_slice(&buf[..n]);
                        while let Some(frame) = pop_tcp_frame(rx_buf) {
                            raw_frames.push(frame);
                        }
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e),
                }
            },
        }
        for frame in raw_frames {
            self.process_turn_frame(&frame, out);
        }
        Ok(())
    }

    fn process_turn_frame(&mut self, frame: &[u8], out: &mut Vec<(SocketAddr, Vec<u8>)>) {
        if frame.len() < 4 {
            return;
        }
        let first_two = u16::from_be_bytes([frame[0], frame[1]]);
        // ChannelData: top two bits == 0b01 (0x4000..=0x7FFF)
        if (0x4000..=0x7FFF).contains(&first_two) {
            let len = u16::from_be_bytes([frame[2], frame[3]]) as usize;
            if 4 + len <= frame.len() {
                if let Some(&peer) = self.chan_to_peer.get(&first_two) {
                    out.push((peer, frame[4..4 + len].to_vec()));
                }
            }
            return;
        }

        // STUN / TURN control or Data Indication
        let Some(parsed) = parse_stun(frame) else {
            return;
        };
        match parsed.msg_type {
            MSG_DATA_IND => {
                let mut peer = None;
                let mut data = None;
                for (t, v) in parsed.attrs {
                    match t {
                        ATTR_XOR_PEER_ADDRESS => peer = parse_xor_addr(v),
                        ATTR_DATA => data = Some(v),
                        _ => {}
                    }
                }
                if let (Some(p), Some(d)) = (peer, data) {
                    out.push((p, d.to_vec()));
                }
            }
            MSG_CHANNEL_BIND_OK => {
                if let Some((peer, chan)) = self.pending_binds.remove(&parsed.tx_id) {
                    if let Some(entry) = self.peers.get_mut(&peer) {
                        if entry.channel == chan {
                            entry.bound = true;
                            entry.last_refresh = Instant::now();
                        }
                    }
                }
            }
            MSG_CREATE_PERM_OK | MSG_REFRESH_OK => {}
            MSG_REFRESH_ERR | MSG_CREATE_PERM_ERR | MSG_CHANNEL_BIND_ERR => {
                // Handle RFC 5389 438 Stale Nonce by adopting the server's fresh nonce.
                let mut code = None;
                let mut fresh_nonce = None;
                for (t, v) in parsed.attrs {
                    match t {
                        ATTR_ERROR_CODE => code = parse_error_code(v),
                        ATTR_NONCE => fresh_nonce = std::str::from_utf8(v).ok().map(|s| s.to_string()),
                        _ => {}
                    }
                }
                if code == Some(438) {
                    if let Some(n) = fresh_nonce {
                        self.nonce = n;
                    }
                }
            }
            _ => {}
        }
    }
}

/// Extract one complete STUN or ChannelData frame from a TCP TURN byte stream (RFC 5766 §11.5).
fn pop_tcp_frame(buf: &mut Vec<u8>) -> Option<Vec<u8>> {
    if buf.len() < 4 {
        return None;
    }
    let first_two = u16::from_be_bytes([buf[0], buf[1]]);
    let total_padded = if (0x4000..=0x7FFF).contains(&first_two) {
        let len = u16::from_be_bytes([buf[2], buf[3]]) as usize;
        let pad = (4 - (len % 4)) % 4;
        4 + len + pad
    } else if (buf[0] & 0xC0) == 0 {
        if buf.len() < 20 {
            return None;
        }
        let len = u16::from_be_bytes([buf[2], buf[3]]) as usize;
        20 + len
    } else {
        // Desynchronized byte; discard to avoid deadlock.
        buf.drain(..1);
        return None;
    };
    if buf.len() < total_padded {
        return None;
    }
    let frame = buf[..total_padded].to_vec();
    buf.drain(..total_padded);
    Some(frame)
}
