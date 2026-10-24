# R3 local content acceptance — current 16kHz vendor clock passed

## Current controller acceptance — 2026-10-24

The decision04 Agent/helper pair was deployed and passed local bidirectional content acceptance on the current firmware with a16kHz vendor voice clock. The authoritative sources are [R3_ACCEPTANCE_EVIDENCE.json](R3_ACCEPTANCE_EVIDENCE.json) for deployment, user feedback, counters, fault checks, resources and final state, and [R3_DIAGNOSTIC_EVIDENCE.json](R3_DIAGNOSTIC_EVIDENCE.json) for preceding failures and clock investigations. Earlier failed attempts below are retained as history and are superseded by this final successful content loop; historical “pending” statements describe their stage, not current acceptance status.

The user explicitly reported “听清楚了！声音质量还可以” and separately confirmed “是，听到了自己的回声”. During75.004 seconds, the external8kHz stream carried3750 frames in each direction with zero external sequence gaps. Native capture was8kHz and playback16kHz. Xruns were zero (omitted zero fields); helper input_drops=14, approximately0.37% of3750 uplink frames, so this was not a zero-drop run. silence_samples=5760 counts native16kHz samples, equivalent to0.36 seconds. echo_dropped=1435 primarily reflects deliberate host discards during prompts/non-echo windows, not network packet loss.

Real fault checks passed: killing the owned helper with SIGKILL produced helper_exit, PCM closure and child reaping; a new session succeeded and the old token was rejected; client EOF produced media_read; ending the call revoked the lease with lease_revoked. Final evidence shows no active call, no owned helper,5c/5p/9c/55p closed, control ready and identity unchanged.

Sampled Agent RSS was8516–12696KiB, with12/16 FDs and7/9 threads; helper RSS was152KiB with7 FDs and4 threads. Sampled one-core CPU mean/max was12.44%/15.32% for Agent and3.51%/3.74% for helper. These are observations from the source evidence, not endurance guarantees. Exact deployed Agent/helper hashes match [R3_BUILD_EVIDENCE.json](R3_BUILD_EVIDENCE.json) and the acceptance deployment record.

Runtime `voice_ready=false` and `verification=unverified` deliberately remain the experimental publication gate despite this scoped content pass. Vendor8kHz playback has unit tests only;30-minute/100-session endurance, Mac microphone/speaker, and ECS/Worker/iOS end-to-end paths remain unverified. R4–R5 are not started. Audio remained in memory; no recording, PCM content or token is added to these documents.

2026-10-24. Implementation follows [the controller contract](../../docs/RM500_AGENT_R3.md), including fixed helper-error reporting and the helper's independent two-second final-exit alarm. Changes are confined to `module/airsim-agent/` and `module/rm500/audio/`. The execution chat has not deployed, called, captured, played audio or changed mixer. The controller deployed the initial build and observed a pcm_config startup failure; that failure and the subsequent probe are retained below. The controller subsequently verified320×2 configuration and deployed it; media handshake passed but audio failed as described under decision02 below. These were intermediate failures; the final decision04 deployment and successful loop are recorded above.

The Go Agent remains CGO=0. It starts a separate static C helper only after a created media session's client authenticates and the active-call lease is rechecked. Idle and unconnected sessions never open PCM. `--audio-helper` must identify a regular executable file; an unconfigured helper is unavailable. Version is `2.0.0-dev.r3`; capabilities and `/v2/local/audio` describe implemented/unverified audio, and voice_ready remains false.

## Local interface

- POST `/v2/local/audio/sessions`: exact request_id, agent_boot_id, backend_epoch, call_id, all UUIDv4; application/json, maximum1024 bytes. Returns201 with session_id, token, binding, fixed external format and media_socket; identical active request returns200; conflict409; recently closed request410. Closed-history bound64.
- GET `/v2/local/audio`: availability and current/last session status, actual configuration and statistics; no token or PCM. Stable helper error codes remain visible in reason.
- DELETE `/v2/local/audio/sessions/<session_id>`:204 for that active or recently closed session;404 for a different/unknown session. Does not hang up calls.
- `/run/airsim-v2/media.sock`:0600 in0700 directory, same live/stale/inode ownership protection as the control socket. At most four concurrent accepted handshakes; excess sockets close. First message is uint32LE length plus exact session_id/token JSON, maximum1024 bytes. Successful reply has ok and8000/mono/s16le/160 format fields. The token binds once and cannot reconnect.
- Client sends a full360-byte ASMP uplink frame every20ms, including zeros when silent. Downlink is the same framing with direction2. See the native helper README for byte layout. No AIRSIMPCM1 compatibility endpoint or device TCP listener is added.

The coordinator exposes a nonsensitive qualification snapshot and coalesced notifications. A generation number remembers intervening invalid states, so held→active cannot silently reuse the old lease. Unique managed active call, boot, epoch, call_id and control trust are checked at create and bind, on event notifications and every100ms. Call/epoch/state loss stops audio without implicitly hanging up the call.

Bounds: three-second handshake, five seconds to connect, two seconds without a complete valid uplink frame,100ms writes,30-minute total session lifetime. Stop closes I/O and reaps the helper; a nonresponsive child is killed after two seconds. All transfers remain in anonymous sockets/memory; no test PCM files are written.

## Local validation

- Strict frame/version/direction/UUID/header/payload/reserved/sequence checks, fragmentation, length limits, duplicate/unknown JSON fields and fixed error-code whitelist.
- Idempotent/conflicting/recently-closed create; stale boot/epoch/call and transient lease revocation; wrong session cannot stop another one; revoked handshake cannot start helper.
- Duplex fake stream, token single binding, mismatched-session frames, client EOF and uplink timeout, blocked helper write, helper exit, Agent shutdown and socket cleanup.
- Four-handshake bound, no-client expiry without helper, regular-file/live-socket preservation.
- Actual subprocess kill/reap using a nonresponsive test binary, without PCM.
- Native protocol tests under address/undefined sanitizers: C/ASMP validation, sequence gaps, three-in-ten-second recovery policy, bounded blocked writes and EOF.
- Full Go race/vet and ARM64 static builds are recorded in `R3_BUILD_EVIDENCE.json` after completion. Vendor hashes are verified before each helper build.

## Controller-only deployment and acceptance

Do not treat the commands below as already executed. Controller must first confirm no live call/session, verify current PID/exe, preserve identity and commands.json, retain R2 rollback binaries, and check userdata space. Upload each artifact into a new hash-specific release directory and verify device SHA256. Do not overwrite a mapped executable or delete locks/fences.

```text
# Host artifacts:
module/airsim-agent/dist/airsim-agent
module/rm500/audio/dist/airsim-audiod

# On device, after explicit controller approval and a verified idle SIGTERM:
<helper-release>/airsim-audiod --version
nohup setsid <agent-release>/airsim-agent --profile rm500u-embedded \
  --at-device /dev/smd1 --audio-helper <helper-release>/airsim-audiod \
  </dev/null >/run/airsim-v2/agent-r3.log 2>&1 &
# Then verify actual PID/exe, identity, journal, health/control/audio and permissions.
```

Only the controller handles actual calls and the bounded media harness. Current acceptance uses the authorized iPhone and the controller's finite-delay0.5-gain echo harness; no implementation change is inferred from that test setup. The current16kHz local content loop, user confirmation and scoped resource/fault observations passed as recorded above. Nonzero RMS alone is not evidence of useful audio. No gain boost, noise gate or denoising is applied to conceal silence residue. Thirty-minute continuous/100-session stability is not yet validated. No autostart, production relay, recording persistence or verified profile is enabled.


## Historical implementation and diagnostic record

All stage-specific results and pending checks below describe the sequence before final acceptance, unless explicitly marked current. The two controller evidence files above are authoritative for the final outcome.

### First hardware failure and controller parameter revision

The controller's first R3 call reached active, but the initial helper reported `pcm_config` in approximately60ms before emitting any frames. The controller then performed a targeted hangup;9c/55p were closed and Agent PID16390 remained ready. This is a failed audio startup, not audio acceptance. Initial artifact hashes remain in [R3_INITIAL_BUILD_EVIDENCE.json](R3_INITIAL_BUILD_EVIDENCE.json).

The controller ran the independent configuration-only probe. Its original JSON is preserved without alteration in [R3_PCM_CONFIG_INITIAL_PROBE.json](R3_PCM_CONFIG_INITIAL_PROBE.json): for both9c and55p, requested160×4 refined to actual period320/count4; proc hw_params reported buffer1280, while TinyALSA get_buffer_size still returned640. Rate8000, mono andS16_LE were correct. No vendor patch or inferred fallback was applied.

Controller decision: explicitly request period_size320, period_count2, start_threshold320, stop_threshold640 and avail_min320 in both directions. External/work frames remain160 samples/320bytes/20ms. The revised helper validates proc period320/buffer640 and config count2 plus thresholds; ready reports the actual validated proc values. Go parsing/fakes now require320×2 and reject the original160×4 or mismatched1280-buffer ready messages. Mixer, gains and resampling remain unchanged.

Revised probe, helper and Agent hashes are in the current build evidence. The helper build now uses`-Wl,-s`. Scope checks comprise media/HTTP race tests, full vet, C protocol sanitizer tests, pinned vendor verification, and static ARM64 ELF inspection. These were the pre-deployment checks for the320×2 build. Subsequent controller evidence and the next build are recorded below.


## Controller diagnostic decision 02 — local fix complete, hardware pending

The controller reports that320×2 configuration and media handshake passed. The third real call produced no capture samples in two seconds, while playback reported45,123,360 samples at1005ms. This is a failed audio run. The execution chat performed no ADB, deployment, calls, real PCM I/O or mixer operations for this fix.

The original TinyALSA vendor files and SHA256 manifest are unchanged. Both helper and configuration probe now compile `dist/tinyalsa/pcm.c`, generated by `scripts/prepare_vendor.py`. The script verifies all vendor hashes, the exact original file hash, the exact single-hunk patch bytes and the resulting file hash. It performs no fuzzy patching. `patches/SOURCE.json` records the controller-verified [official upstream commit](https://github.com/tinyalsa/tinyalsa/commit/a36d521c328b16b53360a016aa543491d0aad05e). The sole backport changes pcm_state's pcm_sync_ptr flags from0 to APPL|AVAIL_MIN. Resulting pcm.c SHA256: `8ce7242dbe569ad53165ed54bb0965c90d091692f080f737cd2115d5804ac514`.

Capture's worker explicitly prepares then starts before the first read and after EPIPE/ESTRPIPE recovery. Playback prepares initially and during recovery, without explicit START; writes retain threshold-based startup. Every positive partial transfer increments the actual sample count and then checks cumulative samples against `8 * (monotonic_now_ms - helper_started_ms) + 1280`. Exceeding the bound terminates with existing `pcm_io`; offending samples remain counted. No pacing sleep, resampling, fake timestamps or dropped counts are introduced. Existing no-progress timeout and recovery budget remain unchanged. Go source, API and the Agent binary are unchanged.

Validation: `sh module/rm500/audio/scripts/test.sh` passes native ASan/UBSan protocol tests, actual helper workers/transfer functions against fake PCM, and the exact upstream pcm_state/pcm_sync_ptr functions against a host fake ioctl. The worker tests cover first capture prepare/start/read order, first playback prepare/write order with no START, both EPIPE and ESTRPIPE recoveries, prepare/start failures, partial positive transfers, exact rate-bound acceptance, immediate overrun termination in both directions with counts retained, and continuing8000Hz progress. The state test preserves live kernel application/avail pointers, refreshes the userspace copy, propagates ioctl failure, and leaves the mapped-status path unchanged. Its negative control against the original unpatched functions exits1 as expected. The host fixture models pointer-exchange semantics only; it does not emulate the Linux PCM ABI or prove driver behavior.

`build.sh` and `build-config-probe.sh` both pass with Zig0.15.2. Both stripped artifacts are ELF64 little-endian AArch64, with no PT_INTERP or PT_DYNAMIC. Current hashes/sizes are in `R3_BUILD_EVIDENCE.json`; the previous320×2 build evidence is preserved in `R3_320X2_BUILD_EVIDENCE.json`. Previous Go race/vet results are historical and were not rerun for this C-only revision.

Controller verification still required: deploy by hash, verify real capture starts and both sample counters track elapsed time, then verify recognizable bidirectional content and user hearing confirmation, failure cleanup and resource behavior. No hardware success is claimed for this build; voice_ready remains false. Thirty-minute/100-session stability remains unverified.

## Controller diagnostic decision 03 — cadence probe built only

Controller reports that the deployed decision02 helper reached active/ready, then exited with xrun_budget at approximately64ms with no capture, before the first statistics message. No hardware success is inferred.

`module/rm500/audio/tests/pcm-cadence-probe.c` and `scripts/build-cadence-probe.sh` add an independent controller-run diagnostic. Both9c and55p are opened before independent worker threads begin, using fixed8000Hz mono S16_LE/320×2 and160-frame requests. Both workers prepare explicitly; only capture explicitly starts. Each worker has a320-byte PCM buffer; playback stays zero and captured bytes are wiped immediately after each call. No PCM or content statistics are emitted.

Output is flushed JSON lines of metadata. Each direction stops after at most32 recorded operations (including open/prepare/start/poll), or the shared two-second deadline. Each operation saves rc/errno immediately, records relative completion time, then queries safe patched pcm_state with a separate state_errno. Positive transfer counts are retained. EAGAIN/zero return polls with20ms timeout; EPIPE preserves the first failure snapshot before at most one prepare/restart recovery; a second EPIPE or another terminal error stops that direction. The first failure's status/hw_params/sw_params are each limited to4096 bytes and JSON escaped, with readable/truncated flags. Main stops, joins and closes after two seconds; SIGALRM has its default terminating action at three seconds, including during a blocked join/close/output. An alarm termination may leave partial metadata without a final summary. Exit1 denotes an observed failure (including a recovered EPIPE), not missing output.

Build and static ELF inspection passed; pinned vendor and exact backport hashes passed. Formal helper hash and Go remain unchanged. No probe execution or device operation was performed by the execution chat. Artifact hash/size and validation limits are in `R3_CADENCE_PROBE_BUILD_EVIDENCE.json`. Only the controller deploys/runs this diagnostic and decides the next implementation change. Idle probe results do not replace real-call audio acceptance.

## Decision03 startup revision — awaiting controller hardware test

Controller's fourth-call kernel evidence places four playback START→STOP sequences before capture START. Idle probing cannot establish uplink timing: playback prepare returned EINVAL without an active backend. This revision implements only the controller's frozen startup experiment.

Playback start_threshold is640 (full buffer); capture remains320. Both retain period320×2, stop640 and avail320; hw_verify checks start threshold per direction. After hardware verification, main performs prepare(capture), prepare(playback), start(capture), in that exact order. Any failure goes directly to cleanup. Only after all succeed does it send ready and start workers. Workers no longer repeat initial prepare; recovery still explicitly prepares and starts capture only. Rate guard and xrun budget are unchanged.

Cleanup has a single error-emission site: if ready was sent successfully, send final stats then error (if any), then media shutdown, join and close. Before ready, send only error (if any) before shutdown; no stats can obscure the Go handshake failure reason. The existing two-second exit alarm and bounded control writes apply. Go/API and vendor/backport are unchanged.

Both diagnostic probes now request capture start320/playback start640. The cadence probe otherwise retains its diagnostic worker startup behavior; this parameter sync does not turn it into the formal helper. ASan/UBSan regressions pass for directional hw_verify acceptance/rejection, exact prepare/prepare/start ordering and fail-fast behavior, no duplicate initial worker prepare, runtime stats→error→shutdown, pre-ready error→shutdown, normal stats→shutdown, recovery and sample-rate checks. Original/patched fake ioctl tests and protocol tests also pass. All three C artifacts build and verify static AArch64. Current hashes are in R3_BUILD_EVIDENCE.json; decision02 evidence is preserved separately. No deployment/device operation was performed; voice_ready remains false pending real-call verification.

## Cadence probe v2 — two-second evidence window

The controller's fifth call reported capture160/playback1440, last progress3ms and final stats52ms with no xrun, ending on the formal helper's unchanged rate guard. This does not distinguish initial prefill from sustained abnormal rate.

Only cadence probe implementation changed in this revision. The32-operation limit now limits emitted operation records, not worker processing. Workers continue until the shared two-second deadline, a terminal error, or cumulative successful samples strictly exceeding32000 in that direction; offending samples remain counted and sample_limit is explicit. Total operation counts continue beyond32. Main initializes prepare capture→prepare playback→start capture before creating workers. Capture threshold320/playback640 and the remaining parameters are unchanged. EPIPE recovery remains at most once per direction, with the first failure saved before recovery.

Each direction has at most three proc snapshot sets, identified by phase first_failure, first32, and end. Each set includes bounded4096-byte status/hw_params/sw_params text, retaining hw_ptr/appl_ptr when the kernel exposes them; no pointers are synthesized. Snapshot context includes time, sample/operation counts and last operation result/errno. Both end snapshots are taken after joining and before closing either PCM. Missing first32 means that32 recorded operations were never reached. Playback remains all-zero; capture memory is immediately wiped. The3-second terminating alarm remains active through output/cleanup. No PCM content statistics are produced.

Warnings-as-errors static ARM64 build, ELF inspection and original-vendor/backport hash checks passed. Runtime/device execution was not performed. Formal helper and Agent artifact hashes were checked unchanged. Current probe hash/size is in R3_CADENCE_PROBE_BUILD_EVIDENCE.json. Only the controller will run this probe inside a controlled active call; no claim of audio success or change to voice_ready is made.

## Cadence probe v3 — explicit playback rate comparison

Controller reports the sixth active-call probe captured16000 samples and played30400 in two seconds with zero xrun, despite requested8kHz playback. Hardware-pointer progress and vendor call metadata motivate a controlled8kHz/16kHz comparison; they do not by themselves establish a supported production profile.

Probe invocation now requires exactly `--playback-rate 8000` or `--playback-rate 16000`; `--version` remains non-I/O. Capture stays8000Hz/160 frames. Playback requests the chosen rate and160/320 frames respectively (20ms). Each worker uses a fixed640-byte array; capture uses only the first320 bytes and wipes them immediately. Period320×2, capture start320, playback start640, stop640 and avail320 remain unchanged. The maximum poll timeout is10ms with no audio pacing sleep. The existing main-thread timer wait only bounds lifecycle, not transfer cadence.

Each variant retains the shared two-second deadline and three-second alarm, with a strict greater-than64000 sample guard per direction. Up to four progress records per direction report cumulative samples and actual elapsed_ms at500ms intervals; a direction that stops early emits fewer records. No catch-up records invent historical counters. The first32 operation records, three bounded proc snapshot phases, sequential initial prepare/prepare/start and one EPIPE recovery remain. Final summaries retain full sample counts.

`sh module/rm500/audio/scripts/test-cadence-options.sh` passed ASan/UBSan parameter boundary tests: both valid rates/frame mappings, missing/extra arguments, wrong option, near-boundary and other rates, malformed numeric strings, whitespace/signs/leading zero and oversized number rejection. Warning-clean static ARM64 build, vendor/backport verification and ELF inspection passed. No probe/device execution was performed. Formal helper/Go remain unchanged. Current probe hash/size is in R3_CADENCE_PROBE_BUILD_EVIDENCE.json; prior v2 evidence is retained separately. Controller alone runs the variants during the controlled active call and reads vendor device5 metadata.

## Decision04 — native playback follows vendor clock; subsequently accepted at16kHz

The controller's seventh-call comparison established vendor5p/5c16kHz, capture8kHz, and playback16kHz steady progress regardless of an8kHz request. This build implements the frozen decision04 and supersedes the earlier same-rate assumptions. No deployment/device operation was performed by the execution chat.

External handshake/ASMP remain8000Hz mono S16_LE/160 samples. Capture remains native8kHz. Before opening its own PCMs, helper reads only `/proc/asound/card0/pcm5p/sub0/hw_params`; it accepts only S16_LE mono8000/16000Hz, rejects closed/missing/malformed/duplicate/oversized metadata with pcm_config, and never opens device5. The same clock is rechecked after initialization before ready and every second thereafter; any format/rate loss or change closes the session instead of switching formats midstream. Hardware verification uses capture8kHz and the selected native playback rate with period320×2, stop640, avail320, capture start320 and playback start640.

Playback consumes one external frame per native20ms frame:8kHz passes through160 samples;16kHz expands to320 in one640-byte buffer, working backward in place. The frozen formula uses signed32-bit `(previous+x)/2`, truncating toward zero, followed by x. The previous sample persists across frames, starts at zero and resets on playback xrun before explicit recovery. Zero-fill frames use the same conversion. Native transfer counts remain actual driver-returned samples. The rate guard is native_rate×elapsed_ms/1000+1280 and PCM poll timeout is10ms; no software audio pacing is added. Startup ordering, recovery budget and ready-aware final stats/error ordering remain unchanged.

Ready now includes nested capture.sample_rate=8000 and playback.sample_rate=8000 or16000. Go strictly validates both and retains them in the existing session.actual diagnostic object, including JSON serialization; no manager architecture or external format changes were needed. Old helper ready messages missing nested rates are rejected, so the Agent/helper pair must be deployed together. voice_ready remains false.

Validation completed: full Go `go test -race ./...` and `go vet ./...`; native ASan/UBSan protocol, PCM flow, exact-source fake ioctl and audio-format tests. Coverage includes8k byte-identical passthrough,16k positive/negative/extreme interpolation with truncation, cross-frame/zero-frame continuity, xrun reset,160/320 native transfers and corresponding guard boundaries, directional8/16k hardware validation, bounded vendor parser failures and changed-rate rejection, nested ready missing/null/invalid/duplicate rates, and preserved native diagnostics. Both Agent and helper built as static little-endian AArch64 with no PT_INTERP/PT_DYNAMIC; original vendor and single backport hashes remain unchanged. Current hashes/sizes are in R3_BUILD_EVIDENCE.json; previous startup build evidence is retained separately.

The controller subsequently passed the75.004-second local content loop, explicit user hearing/own-voice echo confirmation and lifecycle checks; see the current acceptance section and source evidence above. The8k playback path is unit-tested only and has no narrowband real-call acceptance. Thirty-minute stability and100-session endurance remain unverified.
