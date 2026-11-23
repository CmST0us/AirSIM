//! AirSIM v2 Unified Real-Time Rust Module Engine (`airsim-agent`).
//!
//! Replaces the Go `airsim-agent` + C `airsim-audiod` dual-process split with a single static,
//! zero-GC real-time binary for EG25 QDC507 (ARMv7 Cortex-A7) and RM500U (ARM64):
//! - Dedicated `SCHED_FIFO` real-time OS threads for WebRTC (`str0m` + RFC 2198 RED depth=2 +
//!   RFC 5766/8656 TURN UDP/TCP), Capture+Opus64 encode, and AdaptiveJitter+Opus+WSOLA+ALSA playback.
//! - Lock-free SPSC rings + `eventfd` wakeup between threads (zero Unix sockets, zero GC pauses).
//! - 100% drop-in compatible with existing ECS control/media, SkySIM iOS v2, WebUSB installer,
//!   `run-agent.sh`, and `/usrdata/airsim-v2` persistent state files.

use airsim_agent::at::{fence_present, lock_file, AtManager, DevicePort};
use airsim_agent::audio::alsa::{cleanup_route, AudioProfile};
use airsim_agent::cloud::CloudAgent;
use airsim_agent::control::Coordinator;
use airsim_agent::http_lite;
use airsim_agent::identity::{load_or_create, uuid_v4};
use airsim_agent::journal::Store as JournalStore;
use airsim_agent::local_api::serve_local_socket;
use airsim_agent::modem::{
    failed_fields, sample_hardware, verify_platform, ModemSession, EG25_DEVICE, EG25_PROFILE,
    RM500_PROFILE,
};
use airsim_agent::provision::Provisioner;
use airsim_agent::rtc;
use airsim_agent::sms_pdu::SmsDiagnostics;
use airsim_agent::state::StateStore;
use airsim_agent::usb::UsbServer;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::watch;

pub const ENGINE_VERSION: &str = "2.0.0-rs.3";
pub const HELPER_COMPAT_VERSION: &str = "airsim-audiod 2.0.0-rs.3 libopus-1.5.2 unified-rt-wsola";

fn ensure_private_dir(path: &Path) -> Result<(), String> {
    if !path.exists() {
        fs::create_dir_all(path).map_err(|e| e.to_string())?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    }
    let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_dir() || (meta.mode() & 0o777) != 0o700 {
        return Err("directory_permissions".into());
    }
    Ok(())
}

fn wait_random() -> i32 {
    let mut b = [0u8; 32];
    match getrandom::getrandom(&mut b) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("wait-random failed: {e}");
            1
        }
    }
}

fn handle_audio_helper_shim(args: &[String]) -> i32 {
    if args.len() == 1 && args[0] == "--version" {
        println!("{HELPER_COMPAT_VERSION}");
        return 0;
    }
    if args.len() == 3 && args[0] == "--cleanup" && args[1] == "--profile" {
        let Some(prof) = AudioProfile::from_name(&args[2]) else {
            eprintln!("airsim-audiod: unknown profile");
            return 2;
        };
        return match cleanup_route(prof) {
            Ok(()) => 0,
            Err(e) => {
                eprintln!("airsim-audiod cleanup failed: {e}");
                1
            }
        };
    }
    eprintln!("airsim-audiod: unified engine handles media in-process");
    2
}

struct CliArgs {
    profile: String,
    at_device: String,
    data_dir: String,
    runtime_dir: String,
    cloud_config: String,
    usb_listen: String,
    selftest_webrtc_port: Option<u16>,
}

fn parse_cli() -> Result<CliArgs, i32> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(|s| s.as_str()) == Some("--audio-helper-shim") {
        std::process::exit(handle_audio_helper_shim(&args[1..]));
    }

    let mut out = CliArgs {
        profile: RM500_PROFILE.to_string(),
        at_device: "/dev/smd1".to_string(),
        data_dir: String::new(),
        runtime_dir: "/run/airsim-v2".to_string(),
        cloud_config: String::new(),
        usb_listen: String::new(),
        selftest_webrtc_port: None,
    };

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--version" => {
                println!("{ENGINE_VERSION}");
                std::process::exit(0);
            }
            "--wait-random" => {
                std::process::exit(wait_random());
            }
            "--profile" => {
                i += 1;
                out.profile = args.get(i).cloned().unwrap_or_default();
            }
            "--at-device" => {
                i += 1;
                out.at_device = args.get(i).cloned().unwrap_or_default();
            }
            "--data-dir" => {
                i += 1;
                out.data_dir = args.get(i).cloned().unwrap_or_default();
            }
            "--runtime-dir" => {
                i += 1;
                out.runtime_dir = args.get(i).cloned().unwrap_or_default();
            }
            "--audio-helper" => {
                // Accepted for drop-in CLI compatibility with existing run-agent.sh; audio runs in-process.
                i += 1;
            }
            "--cloud-config" => {
                i += 1;
                out.cloud_config = args.get(i).cloned().unwrap_or_default();
            }
            "--usb-listen" => {
                i += 1;
                out.usb_listen = args.get(i).cloned().unwrap_or_default();
            }
            "--selftest-webrtc-server" => {
                i += 1;
                out.selftest_webrtc_port = args.get(i).and_then(|s| s.parse().ok());
            }
            other => {
                eprintln!("unknown flag: {other}");
                return Err(2);
            }
        }
        i += 1;
    }
    Ok(out)
}

/// Self-test WebRTC HTTP server (`POST /offer` -> `{"answer":...}`, `GET /stats` -> JSON)
/// for running real iOS Simulator `WebRTC.framework` 155.0.0 `Probe.swift` directly against
/// our Rust `str0m` + Opus 64k + RED depth=2 + WSOLA engine!
async fn run_selftest_webrtc_server(port: u16) -> Result<(), String> {
    use http_lite::{read_http_request, write_http_response, HttpResponse};
    use rtc::{MediaSessionConfig, MediaSessionHandle, MediaSessionStatus};
    use std::net::Ipv4Addr;
    use tokio::net::TcpListener;

    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|e| e.to_string())?;
    eprintln!("selftest webrtc server listening on 127.0.0.1:{port}");
    let active: Arc<std::sync::Mutex<Option<MediaSessionHandle>>> =
        Arc::new(std::sync::Mutex::new(None));

    loop {
        let (mut stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
        let active_ref = active.clone();
        tokio::spawn(async move {
            let Ok(Some(req)) = read_http_request(&mut stream, Duration::from_secs(10)).await else {
                return;
            };
            let resp = match (req.method.as_str(), req.path.as_str()) {
                ("POST", "/offer") => {
                    let is_raw_sdp = req.body.starts_with(b"v=0");
                    let offer_sdp = if is_raw_sdp {
                        String::from_utf8_lossy(&req.body).to_string()
                    } else if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&req.body) {
                        v.get("offer")
                            .and_then(|s| s.as_str())
                            .unwrap_or("")
                            .to_string()
                    } else {
                        String::from_utf8_lossy(&req.body).to_string()
                    };
                    let cfg = MediaSessionConfig {
                        session_id: uuid_v4().unwrap_or_else(|_| "selftest".into()),
                        offer_sdp,
                        ice_servers: Vec::new(),
                        local_ip: Some(Ipv4Addr::LOCALHOST),
                        gather_timeout: Duration::from_secs(4),
                        audio_profile: AudioProfile::MockLoopback,
                        max_duration: Duration::from_secs(120),
                    };
                    match MediaSessionHandle::start(cfg, Box::new(|| {}), Box::new(|_| {})) {
                        Ok(handle) => {
                            let answer = handle.answer_sdp.clone();
                            *active_ref.lock().unwrap() = Some(handle);
                            if is_raw_sdp {
                                HttpResponse {
                                    status: 200,
                                    headers: vec![("Content-Type".into(), "text/plain".into())],
                                    body: answer.into_bytes(),
                                }
                            } else {
                                HttpResponse::json(200, &serde_json::json!({"answer": answer}))
                            }
                        }
                        Err(e) => HttpResponse::json(400, &serde_json::json!({"error": e})),
                    }
                }
                ("GET", "/stats") => {
                    let g = active_ref.lock().unwrap();
                    if let Some(ref h) = *g {
                        let st = MediaSessionStatus::from_counters(
                            &h.session_id,
                            "streaming",
                            "",
                            &h.candidate_label,
                            &h.counters,
                        );
                        let non_zero = h
                            .counters
                            .synthetic_decoded_non_zero
                            .load(std::sync::atomic::Ordering::Relaxed);
                        HttpResponse::json(
                            200,
                            &serde_json::json!({
                                "primary": st.packets_received,
                                "packets_sent": st.packets_sent,
                                "invalid": st.invalid_audio_packets,
                                "decoded_non_zero_samples": non_zero,
                                "wsola_accelerated": st.wsola_accelerated,
                                "wsola_expanded": st.wsola_expanded,
                                "queue_drops": st.queue_drops,
                                "plc_frames": st.plc_frames,
                                "gc_cycles": st.gc_cycles,
                            }),
                        )
                    } else {
                        HttpResponse::json(200, &serde_json::json!({"primary": 0, "invalid": 0}))
                    }
                }
                ("POST", "/stop") => {
                    let mut g = active_ref.lock().unwrap();
                    if let Some(mut h) = g.take() {
                        h.join();
                    }
                    HttpResponse::json(200, &serde_json::json!({"stopped": true}))
                }
                _ => HttpResponse::empty(404),
            };
            let _ = write_http_response(&mut stream, &resp, false).await;
        });
    }
}

async fn run_agent(cli: CliArgs) -> Result<(), String> {
    let audio_profile = match cli.profile.as_str() {
        EG25_PROFILE => {
            if cfg!(target_os = "linux") && (cli.at_device != EG25_DEVICE || std::env::consts::ARCH != "arm") {
                return Err("profile_mismatch".into());
            }
            AudioProfile::Eg25Qdc507
        }
        RM500_PROFILE => {
            if cfg!(target_os = "linux") && std::env::consts::ARCH != "aarch64" {
                return Err("profile_mismatch".into());
            }
            AudioProfile::Rm500uEmbedded
        }
        _ => return Err("profile_mismatch".into()),
    };

    let data_dir = if cli.data_dir.is_empty() {
        if cli.profile == EG25_PROFILE {
            PathBuf::from("/usrdata/airsim-v2")
        } else {
            PathBuf::from("/mnt/data/airsim-v2")
        }
    } else {
        PathBuf::from(&cli.data_dir)
    };
    let runtime_dir = PathBuf::from(&cli.runtime_dir);

    ensure_private_dir(&data_dir)?;
    let _data_lock = lock_file(&data_dir.join("instance.lock")).map_err(|_| "instance_locked")?;
    ensure_private_dir(&runtime_dir)?;
    let _run_lock = lock_file(&runtime_dir.join("instance.lock")).map_err(|_| "instance_locked")?;

    let config_dir = data_dir.join("config");
    let state_dir = data_dir.join("state");
    let identity = load_or_create(&config_dir)?;
    let boot_id = uuid_v4()?;

    let state_store = Arc::new(StateStore::new(
        identity.module_id.clone(),
        boot_id.clone(),
        cli.profile.clone(),
    ));

    let journal_store = match JournalStore::open(&state_dir) {
        Ok(s) => Arc::new(s),
        Err((s, e)) => {
            eprintln!("journal unavailable: {e}");
            Arc::new(s)
        }
    };

    let (coordinator, call_rx, sms_rx) = Coordinator::new(
        boot_id.clone(),
        identity.clone(),
        journal_store,
        state_store.clone(),
    );

    let cloud_path = if cli.cloud_config.is_empty() {
        config_dir.join("cloud.json")
    } else {
        PathBuf::from(&cli.cloud_config)
    };
    let provisioner = Provisioner::open(identity.clone(), cloud_path, cli.profile.clone());
    let sms_diag = Arc::new(SmsDiagnostics::new());

    let usb_server = if !cli.usb_listen.is_empty() {
        Some(UsbServer::configure(
            &cli.usb_listen,
            &config_dir,
            &identity.module_id,
        )?)
    } else {
        None
    };

    let cloud_agent = CloudAgent::new(
        provisioner,
        coordinator.clone(),
        state_store.clone(),
        sms_diag.clone(),
        usb_server,
        boot_id.clone(),
        ENGINE_VERSION.to_string(),
        audio_profile,
    );

    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // Signal handler (SIGTERM / SIGINT)
    {
        let tx = shutdown_tx.clone();
        tokio::spawn(async move {
            #[cfg(unix)]
            {
                let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
                let mut int = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).ok();
                tokio::select! {
                    _ = async { if let Some(ref mut s) = term { s.recv().await; } else { std::future::pending::<()>().await; } } => {}
                    _ = async { if let Some(ref mut s) = int { s.recv().await; } else { std::future::pending::<()>().await; } } => {}
                }
            }
            let _ = tx.send(true);
        });
    }

    // Spawn coordinator call & SMS execution workers
    tokio::spawn(coordinator.clone().run_worker(call_rx, shutdown_rx.clone()));
    tokio::spawn(coordinator.clone().run_worker(sms_rx, shutdown_rx.clone()));

    // Spawn cloud + USB servers
    tokio::spawn(cloud_agent.clone().run(shutdown_rx.clone()));

    // Open AT device (unless crash fence `at-inflight.json` is present)
    let marker = runtime_dir.join("at-inflight.json");
    let mut _device_lock = None;
    let at_manager: Option<Arc<AtManager>> = if fence_present(&marker) {
        state_store.commit(failed_fields("at_desynchronized"), false, "at_desynchronized");
        None
    } else {
        match DevicePort::open(Path::new(&cli.at_device)) {
            Ok((port, dlock)) => {
                _device_lock = Some(dlock);
                match AtManager::start_device(port, marker) {
                    Ok(mgr) => Some(Arc::new(mgr)),
                    Err(_) => {
                        state_store.commit(failed_fields("query_failed"), false, "query_failed");
                        None
                    }
                }
            }
            Err(e) => {
                eprintln!("AT device open failed ({}): {e}", cli.at_device);
                state_store.commit(failed_fields("query_failed"), false, "query_failed");
                None
            }
        }
    };

    // Verify platform, start hardware sampler + ModemSession control loop
    if let Some(at) = at_manager.clone() {
        let prof = cli.profile.clone();
        let st_ref = state_store.clone();
        let coord_ref = coordinator.clone();
        let diag_ref = sms_diag.clone();
        let ledger_path = state_dir.join("eg25-sms-seen");
        let mut sd_modem = shutdown_rx.clone();
        let sd_tx_fault = shutdown_tx.clone();

        tokio::spawn(async move {
            // Verify platform (ATI / AT+CGMR / /etc/quectel-project-subversion)
            let at_v = at.clone();
            let prof_v = prof.clone();
            let verified = tokio::task::spawn_blocking(move || verify_platform(&prof_v, &at_v))
                .await
                .unwrap_or(Err("query_failed"));
            if let Err(reason) = verified {
                eprintln!("platform verification failed: {reason}");
                st_ref.commit(failed_fields(reason), false, reason);
                return;
            }

            // Initial hardware sample + periodic 5 s hardware sampler
            {
                let at_s = at.clone();
                let st_s = st_ref.clone();
                let mut sd_s = sd_modem.clone();
                tokio::spawn(async move {
                    loop {
                        let a = at_s.clone();
                        let s = st_s.clone();
                        let _ = tokio::task::spawn_blocking(move || sample_hardware(&a, &s)).await;
                        if !at_s.is_alive() {
                            st_s.invalidate("at_desynchronized");
                            // Trigger clean process exit so init respawn recovers AT cleanly.
                            let _ = sd_tx_fault.send(true);
                            return;
                        }
                        tokio::select! {
                            _ = sd_s.changed() => return,
                            _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                        }
                    }
                });
            }

            // Control session loop (reconnects automatically if transient query budget exceeded)
            loop {
                if *sd_modem.borrow() || !at.is_alive() {
                    return;
                }
                let at_c = at.clone();
                let lp = ledger_path.clone();
                let dg = diag_ref.clone();
                let conn = tokio::task::spawn_blocking(move || {
                    let (sess, ev_rx) = ModemSession::connect(at_c, Some(lp), dg)?;
                    let initial = sess.initial_calls().map_err(|_| "initial_calls_failed")?;
                    Ok::<_, &'static str>((sess, ev_rx, initial))
                })
                .await;

                match conn {
                    Ok(Ok((sess, mut ev_rx, initial_calls))) => {
                        coord_ref.attach_session(sess.clone(), initial_calls);
                        let c_ev = coord_ref.clone();
                        let ev_task = tokio::spawn(async move {
                            while let Some(ev) = ev_rx.recv().await {
                                c_ev.apply_modem_event(ev);
                            }
                        });
                        sess.run_poll_loop(sd_modem.clone()).await;
                        ev_task.abort();
                        coord_ref.detach_session("backend_unavailable");
                    }
                    _ => {
                        coord_ref.detach_session("backend_unavailable");
                    }
                }

                tokio::select! {
                    _ = sd_modem.changed() => return,
                    _ = tokio::time::sleep(Duration::from_secs(2)) => {}
                }
            }
        });
    }

    // Serve local Unix domain control socket until shutdown
    let sock_path = runtime_dir.join("control.sock");
    let res = serve_local_socket(&sock_path, cloud_agent.clone(), shutdown_rx).await;
    cloud_agent.stop_any_bridge();
    if let Some(at) = at_manager {
        at.close();
    }
    res
}

fn main() {
    let cli = match parse_cli() {
        Ok(c) => c,
        Err(code) => std::process::exit(code),
    };

    // Single-threaded Tokio runtime for the control plane (tiny RAM footprint: 1 thread!).
    // Real-time audio + WebRTC + AT run on dedicated OS threads (SCHED_FIFO for audio/WebRTC).
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build tokio runtime");

    if let Some(port) = cli.selftest_webrtc_port {
        if let Err(e) = rt.block_on(run_selftest_webrtc_server(port)) {
            eprintln!("selftest server error: {e}");
            std::process::exit(1);
        }
        return;
    }

    let run_res = rt.block_on(run_agent(cli));
    rt.shutdown_timeout(Duration::from_secs(2));
    if let Err(e) = run_res {
        eprintln!("airsim-agent exited with error: {e}");
        std::process::exit(1);
    }
}
