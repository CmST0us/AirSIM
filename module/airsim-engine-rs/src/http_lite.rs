//! Ultra-lean HTTP/1.1 client and server (zero hyper/axum/reqwest dependency bloat).
//! Used for:
//! - Outbound HTTPS discovery (`/.well-known/airsim`) over `tokio_rustls::TlsStream`
//! - Inbound local control API over Unix domain socket (`/run/airsim-v2/control.sock`)
//! - Inbound USB local HTTPS server (`192.168.225.1:8577`) over `tokio_rustls::TlsStream`

use std::collections::HashMap;
use std::io;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: String,
    pub target: String, // raw request-target including query string
    pub path: String,
    pub query: String,
    pub headers: HashMap<String, String>, // lowercase header names
    pub body: Vec<u8>,
}

impl HttpRequest {
    pub fn header(&self, name: &str) -> &str {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(|s| s.as_str())
            .unwrap_or("")
    }
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl HttpResponse {
    pub fn json(status: u16, value: &impl serde::Serialize) -> Self {
        let body = serde_json::to_vec(value).unwrap_or_else(|_| b"{}".to_vec());
        Self {
            status,
            headers: vec![
                ("Content-Type".into(), "application/json".into()),
                ("Cache-Control".into(), "no-store".into()),
            ],
            body,
        }
    }

    pub fn empty(status: u16) -> Self {
        Self {
            status,
            headers: vec![
                ("Content-Type".into(), "application/json".into()),
                ("Cache-Control".into(), "no-store".into()),
            ],
            body: Vec::new(),
        }
    }
}

fn status_reason(code: u16) -> &'static str {
    match code {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        410 => "Gone",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

/// Read one HTTP/1.1 request from any async stream (Unix socket or TLS stream).
pub async fn read_http_request<S: AsyncRead + Unpin>(
    stream: &mut S,
    timeout: Duration,
) -> io::Result<Option<HttpRequest>> {
    tokio::time::timeout(timeout, read_http_request_inner(stream))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "http_read_timeout"))?
}

async fn read_http_request_inner<S: AsyncRead + Unpin>(
    stream: &mut S,
) -> io::Result<Option<HttpRequest>> {
    let mut buf = Vec::with_capacity(2048);
    let mut tmp = [0u8; 2048];
    let header_end = loop {
        if let Some(pos) = find_crlfcrlf(&buf) {
            break pos;
        }
        if buf.len() >= MAX_HEADER_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "header_too_large"));
        }
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            if buf.is_empty() {
                return Ok(None);
            }
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof_in_headers"));
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let head_str = std::str::from_utf8(&buf[..header_end])
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "non_utf8_headers"))?;
    let mut lines = head_str.split("\r\n");
    let req_line = lines
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing_req_line"))?;
    let mut parts = req_line.split_whitespace();
    let method = parts
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing_method"))?
        .to_string();
    let target = parts
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing_target"))?
        .to_string();
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target.clone(), String::new()),
    };

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    let mut body = buf[header_end + 4..].to_vec();
    if let Some(cl) = headers
        .get("content-length")
        .and_then(|v| v.parse::<usize>().ok())
    {
        if cl > MAX_BODY_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "body_too_large"));
        }
        while body.len() < cl {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof_in_body"));
            }
            body.extend_from_slice(&tmp[..n]);
        }
        body.truncate(cl);
    } else if headers
        .get("transfer-encoding")
        .is_some_and(|v| v.to_ascii_lowercase().contains("chunked"))
    {
        body = read_chunked(stream, body).await?;
    } else {
        body.clear();
    }

    Ok(Some(HttpRequest {
        method,
        target,
        path,
        query,
        headers,
        body,
    }))
}

pub async fn write_http_response<S: AsyncWrite + Unpin>(
    stream: &mut S,
    resp: &HttpResponse,
    keep_alive: bool,
) -> io::Result<()> {
    let mut out = Vec::with_capacity(256 + resp.body.len());
    out.extend_from_slice(
        format!(
            "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: {}\r\n",
            resp.status,
            status_reason(resp.status),
            resp.body.len(),
            if keep_alive { "keep-alive" } else { "close" }
        )
        .as_bytes(),
    );
    for (k, v) in &resp.headers {
        out.extend_from_slice(format!("{k}: {v}\r\n").as_bytes());
    }
    out.extend_from_slice(b"\r\n");
    out.extend_from_slice(&resp.body);
    stream.write_all(&out).await?;
    stream.flush().await
}

/// Perform a single HTTPS/HTTP GET request over an already-connected async stream.
pub async fn http_get<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    host: &str,
    path: &str,
    max_body: usize,
) -> io::Result<(u16, Vec<u8>)> {
    let req = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: airsim-agent/2.0\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(req.as_bytes()).await?;
    stream.flush().await?;

    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 2048];
    let header_end = loop {
        if let Some(pos) = find_crlfcrlf(&buf) {
            break pos;
        }
        if buf.len() >= MAX_HEADER_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "resp_header_too_large"));
        }
        let n = stream.read(&mut tmp).await?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof_in_resp_headers"));
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let head = std::str::from_utf8(&buf[..header_end])
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad_resp_utf8"))?;
    let mut lines = head.split("\r\n");
    let status_line = lines
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing_status"))?;
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad_status_code"))?;

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }

    let mut body = buf[header_end + 4..].to_vec();
    if headers
        .get("transfer-encoding")
        .is_some_and(|v| v.to_ascii_lowercase().contains("chunked"))
    {
        body = read_chunked(stream, body).await?;
        if body.len() > max_body {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "resp_body_too_large"));
        }
    } else if let Some(cl) = headers
        .get("content-length")
        .and_then(|v| v.parse::<usize>().ok())
    {
        if cl > max_body {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "resp_body_too_large"));
        }
        while body.len() < cl {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof_in_resp_body"));
            }
            body.extend_from_slice(&tmp[..n]);
        }
        body.truncate(cl);
    } else {
        loop {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                break;
            }
            body.extend_from_slice(&tmp[..n]);
            if body.len() > max_body {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "resp_body_too_large"));
            }
        }
    }

    Ok((status, body))
}

async fn read_chunked<S: AsyncRead + Unpin>(
    stream: &mut S,
    mut buf: Vec<u8>,
) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut tmp = [0u8; 2048];
    loop {
        let line_end = loop {
            if let Some(p) = buf.windows(2).position(|w| w == b"\r\n") {
                break p;
            }
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof_chunk_hdr"));
            }
            buf.extend_from_slice(&tmp[..n]);
        };
        let sz_str = std::str::from_utf8(&buf[..line_end])
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad_chunk_hdr"))?
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        let sz = usize::from_str_radix(sz_str, 16)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad_chunk_sz"))?;
        buf.drain(..line_end + 2);
        if sz == 0 {
            return Ok(out);
        }
        if out.len() + sz > MAX_BODY_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "chunk_too_large"));
        }
        while buf.len() < sz + 2 {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "eof_chunk_data"));
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        out.extend_from_slice(&buf[..sz]);
        buf.drain(..sz + 2);
    }
}

fn find_crlfcrlf(b: &[u8]) -> Option<usize> {
    b.windows(4).position(|w| w == b"\r\n\r\n")
}
