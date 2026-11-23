//! Unix domain socket local control API server (`/run/airsim-v2/control.sock`, mode 0600).
//! Mirrors Go `internal/transport/local` + cloud/pairing/SMS diagnostics routes 100%.

use crate::cloud::CloudAgent;
use crate::control::{CommandRequest, ParseCommandError};
use crate::http_lite::{read_http_request, write_http_response, HttpRequest, HttpResponse};
use crate::identity::is_valid_uuid_v4;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UnixListener;
use tokio::sync::watch;

pub async fn serve_local_socket(
    socket_path: &Path,
    agent: Arc<CloudAgent>,
    mut shutdown: watch::Receiver<bool>,
) -> Result<(), String> {
    // Live-socket conflict guard matching Go `local.Serve`: never unlink an active listener.
    match fs::symlink_metadata(socket_path) {
        Ok(meta) => {
            if !meta.file_type().is_socket() {
                return Err("socket_conflict".into());
            }
            match StdUnixStream::connect(socket_path) {
                Ok(_) => return Err("socket_conflict".into()),
                Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused => {
                    let cur = fs::symlink_metadata(socket_path).map_err(|_| "socket_conflict")?;
                    if cur.ino() != meta.ino() || cur.dev() != meta.dev() {
                        return Err("socket_conflict".into());
                    }
                    fs::remove_file(socket_path).map_err(|e| e.to_string())?;
                }
                Err(_) => return Err("socket_conflict".into()),
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.to_string()),
    }

    let listener = UnixListener::bind(socket_path).map_err(|e| e.to_string())?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    let owned_meta = fs::symlink_metadata(socket_path).ok();

    loop {
        tokio::select! {
            _ = shutdown.changed() => break,
            accepted = listener.accept() => {
                if let Ok((mut stream, _)) = accepted {
                    let ag = agent.clone();
                    tokio::spawn(async move {
                        loop {
                            match read_http_request(&mut stream, Duration::from_secs(5)).await {
                                Ok(Some(req)) => {
                                    let keep = req.header("connection").eq_ignore_ascii_case("keep-alive");
                                    let resp = route_local(&ag, &req);
                                    if write_http_response(&mut stream, &resp, keep).await.is_err() || !keep {
                                        break;
                                    }
                                }
                                _ => break,
                            }
                        }
                    });
                }
            }
        }
    }

    if let Some(owned) = owned_meta {
        if let Ok(cur) = fs::symlink_metadata(socket_path) {
            if cur.ino() == owned.ino() && cur.dev() == owned.dev() {
                let _ = fs::remove_file(socket_path);
            }
        }
    }
    Ok(())
}

fn route_local(agent: &Arc<CloudAgent>, req: &HttpRequest) -> HttpResponse {
    // 1. Provisioning & Pairing routes
    if let Some(resp) = agent.provisioner.handle_local_route(req) {
        return resp;
    }

    // 2. Cloud media stats
    if req.path == "/v2/local/cloud/media-stats" {
        if req.method != "GET" {
            return HttpResponse::empty(405);
        }
        return HttpResponse::json(200, &agent.media_stats());
    }

    // 3. SMS diagnostics
    if req.path == "/v2/local/diagnostics/sms" {
        if req.method != "GET" {
            return HttpResponse::empty(405);
        }
        return HttpResponse::json(200, &agent.sms_diag.snapshot());
    }

    // 4. Audio status
    if req.path == "/v2/local/audio" {
        if req.method != "GET" {
            return HttpResponse::empty(405);
        }
        return HttpResponse::json(200, &agent.control.audio_view());
    }

    // 5. Control routes
    match req.path.as_str() {
        "/v2/local/control" => {
            if req.method != "GET" {
                return HttpResponse::empty(405);
            }
            return HttpResponse::json(200, &agent.control.status());
        }
        "/v2/local/calls" => {
            if req.method != "GET" {
                return HttpResponse::empty(405);
            }
            return HttpResponse::json(200, &agent.control.calls_view());
        }
        "/v2/local/messages" => {
            if req.method != "GET" {
                return HttpResponse::empty(405);
            }
            return HttpResponse::json(200, &agent.control.messages_view(false));
        }
        "/v2/local/commands" => {
            if req.method != "POST" {
                return HttpResponse::empty(405);
            }
            if !req
                .header("content-type")
                .to_ascii_lowercase()
                .starts_with("application/json")
            {
                return HttpResponse::empty(400);
            }
            let cmd = match CommandRequest::parse(&req.body) {
                Ok(c) => c,
                Err(ParseCommandError::UnsupportedAction) => return HttpResponse::empty(404),
                Err(_) => return HttpResponse::empty(400),
            };
            let (rcpt, code) = agent.control.submit(cmd);
            return match rcpt {
                Some(r) => HttpResponse::json(code, &r),
                None => HttpResponse::empty(code),
            };
        }
        _ => {}
    }

    if let Some(cmd_id) = req.path.strip_prefix("/v2/local/commands/") {
        if !is_valid_uuid_v4(cmd_id) {
            return HttpResponse::empty(404);
        }
        if req.method != "GET" {
            return HttpResponse::empty(405);
        }
        return match agent.control.command_receipt(cmd_id) {
            Some(r) => HttpResponse::json(200, &r),
            None => HttpResponse::empty(404),
        };
    }

    // 6. Health, Ready, Snapshot, Capabilities
    if req.method != "GET" {
        return HttpResponse::empty(405);
    }
    match req.path.as_str() {
        "/healthz" => HttpResponse::json(
            200,
            &json!({
                "status": "ok",
                "version": agent.version,
                "agent_boot_id": agent.boot_id,
            }),
        ),
        "/readyz" => {
            let (_, ready) = agent.state.view();
            let code = if ready.ready { 200 } else { 503 };
            HttpResponse::json(code, &ready)
        }
        "/v2/local/snapshot" => {
            let (snap, _) = agent.state.view();
            HttpResponse::json(200, &snap)
        }
        "/v2/local/capabilities" => {
            let ctl = agent.control.status();
            let caps = agent.state.capabilities(ctl.messaging_ready, &ctl.reason);
            HttpResponse::json(200, &caps)
        }
        _ => HttpResponse::empty(404),
    }
}
