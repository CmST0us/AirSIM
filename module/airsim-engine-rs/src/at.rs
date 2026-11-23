//! Serialized AT device manager with exclusive flock, Linux raw termios (115200 8N1),
//! tmpfs `at-inflight.json` crash fence, 500 ms startup drain, URC wakeup notifications,
//! and strict command whitelist (including `AT+CMGS` `>` prompt + `\x1a`).

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AtError {
    Desynchronized,
    QueryFailed,
    InvalidResponse,
    Timeout,
}

impl std::fmt::Display for AtError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Desynchronized => f.write_str("at_desynchronized"),
            Self::QueryFailed => f.write_str("query_failed"),
            Self::InvalidResponse => f.write_str("invalid_response"),
            Self::Timeout => f.write_str("timeout"),
        }
    }
}

pub struct FileLock {
    _file: File,
}

pub fn lock_file(path: &Path) -> io::Result<FileLock> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err(io::Error::new(io::ErrorKind::WouldBlock, "lock_busy"));
    }
    Ok(FileLock { _file: file })
}

pub fn fence_present(marker: &Path) -> bool {
    fs::symlink_metadata(marker).is_ok()
}

pub trait AtPort: Read + Write + Send + 'static {
    fn shutdown(&self);
}

pub struct DevicePort {
    fd: RawFd,
    closed: Arc<AtomicBool>,
}

impl DevicePort {
    pub fn open(path: &Path) -> io::Result<(Self, FileLock)> {
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        let cpath = std::ffi::CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "bad_path"))?;
        if unsafe { libc::stat(cpath.as_ptr(), &mut st) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let lock_path = PathBuf::from(format!("/run/lock/rm500-{}.lock", st.st_rdev));
        let lock = lock_file(&lock_path)?;

        let fd = unsafe {
            libc::open(
                cpath.as_ptr(),
                libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }

        // Configure raw 115200 8N1 if the char device is a TTY (ignore ENOTTY on /dev/airsim_data11).
        #[cfg(target_os = "linux")]
        unsafe {
            let mut tio: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(fd, &mut tio) == 0 {
                libc::cfmakeraw(&mut tio);
                tio.c_cflag |= libc::CLOCAL | libc::CREAD | libc::CS8;
                tio.c_cflag &= !(libc::PARENB | libc::CSTOPB | libc::CRTSCTS);
                tio.c_cc[libc::VMIN] = 1;
                tio.c_cc[libc::VTIME] = 0;
                libc::cfsetispeed(&mut tio, libc::B115200);
                libc::cfsetospeed(&mut tio, libc::B115200);
                let _ = libc::tcsetattr(fd, libc::TCSANOW, &tio);
            }
        }

        Ok((
            Self {
                fd,
                closed: Arc::new(AtomicBool::new(false)),
            },
            lock,
        ))
    }
}

impl Read for DevicePort {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.closed.load(Ordering::Relaxed) {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"));
            }
            let mut pfd = libc::pollfd {
                fd: self.fd,
                events: libc::POLLIN,
                revents: 0,
            };
            let pr = unsafe { libc::poll(&mut pfd, 1, 200) };
            if pr < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            if pr == 0 {
                continue;
            }
            if (pfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL)) != 0
                && (pfd.revents & libc::POLLIN) == 0
            {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "hup"));
            }
            let n = unsafe { libc::read(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(e);
            }
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof"));
            }
            return Ok(n as usize);
        }
    }
}

impl Write for DevicePort {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.closed.load(Ordering::Relaxed) {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"));
        }
        let n = unsafe { libc::write(self.fd, buf.as_ptr() as *const libc::c_void, buf.len()) };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl AtPort for DevicePort {
    fn shutdown(&self) {
        self.closed.store(true, Ordering::Release);
    }
}

impl Drop for DevicePort {
    fn drop(&mut self) {
        self.closed.store(true, Ordering::Release);
        unsafe {
            let _ = File::from_raw_fd(self.fd);
        }
    }
}

pub fn is_urc(line: &str) -> bool {
    const EXACT: &[&str] = &[
        "RING",
        "NO CARRIER",
        "BUSY",
        "NO ANSWER",
        "NO DIALTONE",
        "RDY",
        "APP RDY",
        "CALL READY",
        "SMS READY",
        "VOICE CALL: BEGIN",
        "VOICE CALL: END",
        "POWERED DOWN",
    ];
    if EXACT.contains(&line) {
        return true;
    }
    const PREFIXES: &[&str] = &[
        "+CRING:",
        "+CLIP:",
        "+COLP:",
        "+CCWA:",
        "+CSSI:",
        "+CSSU:",
        "+CMTI:",
        "+CMT:",
        "+CDSI:",
        "+CDS:",
        "+CBM:",
        "+CREG:",
        "+CGREG:",
        "+CEREG:",
        "+CIREG:",
        "+CIREGU:",
        "+CGEV:",
        "+QIND:",
        "+QTONEDET:",
        "+QUSIM:",
        "+QCSQ:",
        "+CIEV:",
        "+CTZV:",
        "+CTZE:",
        "+CPIN:",
        "+CFUN:",
        "+CLCC:",
        "VOICE CALL:",
        "^",
    ];
    PREFIXES.iter().any(|p| line.starts_with(p))
}

fn allowed_query_prefix(cmd: &str) -> Option<&'static str> {
    match cmd {
        "ATI" | "AT+CGMR" => Some(""),
        "AT+CPIN?" => Some("+CPIN:"),
        "AT+CSQ" => Some("+CSQ:"),
        "AT+CREG?" => Some("+CREG:"),
        "AT+CGREG?" => Some("+CGREG:"),
        "AT+CEREG?" => Some("+CEREG:"),
        "AT+CIREG?" => Some("+CIREG:"),
        "AT+COPS?" => Some("+COPS:"),
        "AT+CLCC" => Some("+CLCC:"),
        "AT+CPMS?" => Some("+CPMS:"),
        "AT+CNMI?" => Some("+CNMI:"),
        _ => None,
    }
}

fn validate_command(cmd: &str, payload: &str) -> Option<(&'static str, Duration, bool)> {
    if cmd == "ATE0" || cmd == "AT+CMGF=0" || cmd == "ATA" || cmd == "ATH" || cmd == "AT+CHUP" {
        if !payload.is_empty() {
            return None;
        }
        return Some(("", Duration::from_secs(10), false));
    }
    if cmd == "AT+CMGL=4" {
        if !payload.is_empty() {
            return None;
        }
        return Some(("+CMGL:", Duration::from_secs(15), true));
    }
    if let Some(rest) = cmd.strip_prefix("ATD") {
        if !payload.is_empty() || !rest.ends_with(';') {
            return None;
        }
        let num = &rest[..rest.len() - 1];
        if num.is_empty() || num.len() > 20 || !num.bytes().all(|b| b.is_ascii_digit() || b == b'+') {
            return None;
        }
        return Some(("", Duration::from_secs(15), false));
    }
    if let Some(rest) = cmd.strip_prefix("AT+CHLD=") {
        if !payload.is_empty() || !matches!(rest, "0" | "1" | "10" | "11" | "12" | "13" | "14" | "15" | "16" | "17" | "2") {
            return None;
        }
        return Some(("", Duration::from_secs(10), false));
    }
    if let Some(rest) = cmd.strip_prefix("AT+VTS=") {
        if !payload.is_empty() || rest.is_empty() || rest.len() > 36 {
            return None;
        }
        return Some(("", Duration::from_secs(10), false));
    }
    if let Some(rest) = cmd.strip_prefix("AT+CMGD=") {
        if !payload.is_empty() || rest.parse::<u16>().is_err() {
            return None;
        }
        return Some(("", Duration::from_secs(10), false));
    }
    if let Some(rest) = cmd.strip_prefix("AT+CMGS=") {
        if rest.parse::<u16>().is_err()
            || payload.is_empty()
            || payload.len() > 512
            || !payload.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return None;
        }
        return Some(("+CMGS:", Duration::from_secs(30), false));
    }
    None
}

struct AtRequest {
    command: String,
    payload: String,
    prefix: String,
    timeout: Duration,
    pdu_lines: bool,
    reply: mpsc::SyncSender<Result<Vec<String>, AtError>>,
}

pub struct AtManager {
    tx: mpsc::SyncSender<AtRequest>,
    alive: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    urc_notify: Arc<tokio::sync::Notify>,
    port_shutdown: Arc<dyn Fn() + Send + Sync>,
    join_handles: Mutex<Vec<std::thread::JoinHandle<()>>>,
}

impl AtManager {
    pub fn start_device(port: DevicePort, marker: PathBuf) -> io::Result<Self> {
        let dup_fd = unsafe { libc::fcntl(port.fd, libc::F_DUPFD_CLOEXEC, 0) };
        if dup_fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let closed = port.closed.clone();
        let writer = DeviceWriter { fd: dup_fd };
        let mut mgr = Self::start_split(port, writer, marker);
        mgr.port_shutdown = Arc::new(move || closed.store(true, Ordering::Release));
        Ok(mgr)
    }

    pub fn start_split<R, W>(mut reader: R, mut writer: W, marker: PathBuf) -> Self
    where
        R: Read + Send + 'static,
        W: Write + Send + 'static,
    {
        let (req_tx, req_rx) = mpsc::sync_channel::<AtRequest>(16);
        let (line_tx, line_rx) = mpsc::sync_channel::<String>(128);
        let alive = Arc::new(AtomicBool::new(true));
        let stop = Arc::new(AtomicBool::new(false));
        let urc_notify = Arc::new(tokio::sync::Notify::new());
        let fault = Arc::new(AtomicBool::new(false));

        let r_stop = stop.clone();
        let r_fault = fault.clone();
        let reader_handle = std::thread::Builder::new()
            .name("airsim-at-rx".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                let mut buf = [0u8; 1024];
                let mut pending = String::new();
                while !r_stop.load(Ordering::Relaxed) {
                    match reader.read(&mut buf) {
                        Ok(0) => {
                            r_fault.store(true, Ordering::Release);
                            return;
                        }
                        Ok(n) => {
                            let chunk = String::from_utf8_lossy(&buf[..n]);
                            pending.push_str(&chunk);
                            loop {
                                if pending.starts_with('>') {
                                    if line_tx.send(">".to_string()).is_err() {
                                        return;
                                    }
                                    pending.drain(..1);
                                    if pending.starts_with(' ') {
                                        pending.drain(..1);
                                    }
                                }
                                if let Some(idx) = pending.find(['\r', '\n']) {
                                    if idx > 4096 {
                                        r_fault.store(true, Ordering::Release);
                                        return;
                                    }
                                    let line = pending[..idx].trim().to_string();
                                    pending.drain(..=idx);
                                    if !line.is_empty() && line_tx.send(line).is_err() {
                                        return;
                                    }
                                } else {
                                    if pending.len() > 4096 {
                                        r_fault.store(true, Ordering::Release);
                                        return;
                                    }
                                    break;
                                }
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => {
                            r_fault.store(true, Ordering::Release);
                            return;
                        }
                    }
                }
            })
            .expect("spawn at-rx");

        let a_alive = alive.clone();
        let a_stop = stop.clone();
        let a_fault = fault.clone();
        let a_urc = urc_notify.clone();
        let actor_handle = std::thread::Builder::new()
            .name("airsim-at".into())
            .stack_size(128 * 1024)
            .spawn(move || {
                // Startup 500 ms quiet drain (max 5 s)
                let start = Instant::now();
                let mut quiet_until = Instant::now() + Duration::from_millis(500);
                while Instant::now() < quiet_until {
                    if a_stop.load(Ordering::Relaxed) || a_fault.load(Ordering::Acquire) {
                        a_alive.store(false, Ordering::Release);
                        return;
                    }
                    if start.elapsed() > Duration::from_secs(5) {
                        a_alive.store(false, Ordering::Release);
                        return;
                    }
                    let wait = quiet_until
                        .saturating_duration_since(Instant::now())
                        .min(Duration::from_millis(50));
                    if let Ok(_line) = line_rx.recv_timeout(wait) {
                        quiet_until = Instant::now() + Duration::from_millis(500);
                    }
                }

                // Main serialized AT loop
                while !a_stop.load(Ordering::Relaxed) && !a_fault.load(Ordering::Acquire) {
                    // Drain any idle URCs first
                    while let Ok(line) = line_rx.try_recv() {
                        if is_urc(&line) {
                            a_urc.notify_one();
                        } else {
                            // Unexpected unsolicited non-URC line -> desync
                            a_alive.store(false, Ordering::Release);
                            return;
                        }
                    }

                    match req_rx.recv_timeout(Duration::from_millis(50)) {
                        Ok(req) => {
                            let (res, broken) = execute_at(
                                &mut writer,
                                &line_rx,
                                &marker,
                                &req,
                                &a_urc,
                                &a_stop,
                                &a_fault,
                            );
                            let _ = req.reply.send(res);
                            if broken {
                                a_alive.store(false, Ordering::Release);
                                return;
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                }
                a_alive.store(false, Ordering::Release);
            })
            .expect("spawn at-actor");

        Self {
            tx: req_tx,
            alive,
            stop,
            urc_notify,
            port_shutdown: Arc::new(|| {}),
            join_handles: Mutex::new(vec![actor_handle, reader_handle]),
        }
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Acquire)
    }

    pub fn urc_notify(&self) -> Arc<tokio::sync::Notify> {
        self.urc_notify.clone()
    }

    pub fn query(&self, cmd: &str) -> Result<Vec<String>, AtError> {
        let prefix = allowed_query_prefix(cmd).ok_or(AtError::InvalidResponse)?;
        self.submit(cmd, "", prefix, Duration::from_secs(5), false)
    }

    pub fn command(&self, cmd: &str, payload: &str) -> Result<Vec<String>, AtError> {
        let (prefix, timeout, pdu_lines) =
            validate_command(cmd, payload).ok_or(AtError::InvalidResponse)?;
        self.submit(cmd, payload, prefix, timeout, pdu_lines)
    }

    fn submit(
        &self,
        command: &str,
        payload: &str,
        prefix: &str,
        timeout: Duration,
        pdu_lines: bool,
    ) -> Result<Vec<String>, AtError> {
        if !self.is_alive() {
            return Err(AtError::Desynchronized);
        }
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        let req = AtRequest {
            command: command.to_string(),
            payload: payload.to_string(),
            prefix: prefix.to_string(),
            timeout,
            pdu_lines,
            reply: reply_tx,
        };
        self.tx.try_send(req).map_err(|_| AtError::QueryFailed)?;
        reply_rx
            .recv_timeout(timeout + Duration::from_secs(2))
            .map_err(|_| AtError::Desynchronized)?
    }

    pub fn close(&self) {
        self.stop.store(true, Ordering::Release);
        (self.port_shutdown)();
        let handles = std::mem::take(&mut *self.join_handles.lock().unwrap());
        for h in handles {
            let _ = h.join();
        }
    }
}

impl Drop for AtManager {
    fn drop(&mut self) {
        self.close();
    }
}

struct DeviceWriter {
    fd: RawFd,
}

impl Write for DeviceWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = unsafe { libc::write(self.fd, buf.as_ptr() as *const libc::c_void, buf.len()) };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for DeviceWriter {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.fd);
        }
    }
}

fn write_fence(marker: &Path, command: &str) -> io::Result<()> {
    let mut f = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(marker)?;
    write!(f, "{{\"command\":\"{}\"}}", command.replace('"', ""))?;
    Ok(())
}

fn execute_at<W: Write>(
    writer: &mut W,
    line_rx: &mpsc::Receiver<String>,
    marker: &Path,
    req: &AtRequest,
    urc_notify: &tokio::sync::Notify,
    stop: &AtomicBool,
    fault: &AtomicBool,
) -> (Result<Vec<String>, AtError>, bool) {
    if write_fence(marker, &req.command).is_err() {
        return (Err(AtError::Desynchronized), true);
    }
    let wire = format!("{}\r", req.command);
    if writer.write_all(wire.as_bytes()).is_err() {
        return (Err(AtError::Desynchronized), true);
    }

    let deadline = Instant::now() + req.timeout;
    let mut payload_sent = req.payload.is_empty();
    let mut out = Vec::new();
    let mut expect_pdu_hex = false;

    loop {
        if stop.load(Ordering::Relaxed) || fault.load(Ordering::Acquire) {
            return (Err(AtError::Desynchronized), true);
        }
        let rem = deadline.saturating_duration_since(Instant::now());
        if rem.is_zero() {
            return (Err(AtError::Desynchronized), true);
        }
        let line = match line_rx.recv_timeout(rem.min(Duration::from_millis(200))) {
            Ok(l) => l,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => return (Err(AtError::Desynchronized), true),
        };

        // Handle AT echo (in case ATE0 hasn't been sent yet at startup)
        if line == req.command {
            continue;
        }

        if !payload_sent && line == ">" {
            let mut body = req.payload.as_bytes().to_vec();
            body.push(0x1a); // CTRL-Z
            if writer.write_all(&body).is_err() {
                return (Err(AtError::Desynchronized), true);
            }
            payload_sent = true;
            continue;
        }

        if line == "OK" {
            let _ = fs::remove_file(marker);
            return (Ok(out), false);
        }
        if line == "ERROR" || line.starts_with("+CME ERROR:") || line.starts_with("+CMS ERROR:") {
            let _ = fs::remove_file(marker);
            return (Err(AtError::QueryFailed), false);
        }

        if expect_pdu_hex {
            out.push(line);
            expect_pdu_hex = false;
            continue;
        }

        if !req.prefix.is_empty() && line.starts_with(&req.prefix) {
            out.push(line);
            if req.pdu_lines {
                expect_pdu_hex = true;
            }
            continue;
        }

        if is_urc(&line) {
            urc_notify.notify_one();
            continue;
        }

        if req.prefix.is_empty() {
            out.push(line);
            continue;
        }

        // Unrecognized line during prefixed query -> fail safely
        let _ = fs::remove_file(marker);
        return (Err(AtError::InvalidResponse), false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urc_and_command_validation() {
        assert!(is_urc("RING"));
        assert!(is_urc("+CMTI: \"ME\",3"));
        assert!(is_urc("VOICE CALL: BEGIN"));
        assert!(!is_urc("OK"));
        assert!(validate_command("ATD10086;", "").is_some());
        assert!(validate_command("ATD+8613800138000;", "").is_some());
        assert!(validate_command("ATD10086;rm -rf", "").is_none());
        assert!(validate_command("AT+CMGS=24", "001100").is_some());
        assert!(validate_command("AT+CMGS=24", "not-hex").is_none());
    }
}
