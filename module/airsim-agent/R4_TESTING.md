# R4 Agent local implementation handoff

2026-10-24. Implements the controller-frozen [protocol](../../protocol/v2/R4.md) and [R4 scope](../../docs/RM500_AGENT_R4.md). This is Agent-side implementation and isolated local test evidence, not ECS deployment or real cloud call/SMS/audio acceptance. No device, cloud resource, routing, mixer, call or git-index operation was performed. C helper and R3 native audio parameters are unchanged; runtime voice_ready remains false. The accepted R3 binary is retained locally at the path in R4_BUILD_EVIDENCE.json.

## Review/commit scope

Only `module/airsim-agent/` changed: `internal/cloud/{provision,control,bridge}.go` and their tests; `internal/identity/signing.go`; `internal/control/coordinator.go` plus its regression test; `cmd/airsim-agent/main.go`; `go.mod/go.sum`; `scripts/cloud_local.py`, `scripts/test_cloud_local.py`; this record and `R4_BUILD_EVIDENCE.json`. Existing R1–R3 source/tests remain, with one additive coordinator view described below. The controller owns staging/commits; this execution chat did not stage or commit.

Dependency added exactly: github.com/coder/websocket v1.8.15. Existing godbus/dbus v5.2.2 and x/sys v0.27.0 remain. Build uses Go1.24.13, CGO=0, static Linux ARM64. Current version is2.0.0-dev.r4.

## Implemented behavior

Identity's Signer wrapper exposes operations and a copied public key, never the underlying Ed25519 key/seed. Prepare uses the original identity for the exact CSR SAN and proof; pending/config files are strictly parsed, permission checked, atomically replaced and fsynced at0600 under0700. Duplicate prepare/activation is idempotent; mismatched requests/bundles cannot replace the configured server. Activate checks pending binding, expiry, receipt, certificate chain/ClientAuth-only usage, original public key and exact URI-only SAN. Missing config leaves local R3 behavior intact. Malformed/permissive files fail closed without deleting identity. No automatic renewal or credential printing is added.

The local Unix APIs are prepare, activate, status and GET `/v2/local/cloud/media-stats`. The latter returns exactly session_id/state/reason/cloud_input_gaps/local_input_gaps/queue_drops/zero_frames, initially idle/empty/zero, resets for a new bridge and retains closed statistics. Live counters use atomics with protected lifecycle snapshots; no token or PCM is included.

The outbound client verifies HTTPS discovery against all pinned origins/server/profile before mTLS WSS. TLS>=1.2, normal chain/hostname/time verification, optional explicit roots only, no proxy, no redirects, fixed subprotocols and no compression. Incoming envelopes enforce module/connection epoch and strictly consecutive sequences. Control has a32-item encoded queue bounded before enqueue,131072-byte frame limit,3-second writes,5-second hello/welcome handshake,5-second heartbeat and15-second read timeout; reconnect uses the frozen exponential delays plus bounded jitter. A disconnected connection cancels its bridge and never hangs up/replays HAL actions.

Commands are re-parsed through control.Parse and submitted to the existing coordinator with bounded contexts. Receipt queries never Submit. At most64 receipt observations are pending; dial/dtmf/sms accepted ends polling, answer/hangup accepted continues for at most11 seconds, after which the slot is released without fabricating a new state. Ownership is learned only from a call successfully submitted by this cloud runtime with its client/generation; an unrelated pre-existing local journal receipt cannot grant cloud media ownership. Bindings remain bounded by the existing1024-record command journal. Snapshots check control/calls twice for matching boot/epoch; inbox batches are <=32 and <=64KiB. An additive `View("cloud_messages")` filters internal message epochs and sets gap for excluded history; the existing local `messages` view is unchanged.

Media uses the existing R3 manager and protected Unix media authentication after cloud pairing. It preserves PCM bytes, changes only ASMP IDs/independent sequences and retains separate gap/drop/zero counters. Uplink has at most5 queued whole frames, evicts the oldest on overflow and permits at most5 initial zero frames before first cloud input. Cloud/local I/O has bounded deadlines; setup/pair/local binding shares5 seconds. Only this bridge's local session is stopped on EOF/control disconnect/timeout; it does not take over an existing local session. Cloud media has no automatic reconnect.

## Tests and limits of evidence

Full `go test -race ./...` and `go vet ./...` passed, including all existing R1–R3 tests. New tests cover pending/config restart/idempotence, private-material exclusion, file permissions/symlink refusal/save failure, exact proof/receipt verification, wrong public key/SAN/additional SAN/EKU/expired leaf, strict JSON/epoch/sequence, TLS roots/redirect/proxy settings, discovery binding, actual local TLS/mTLS WebSocket hello/command/snapshot/messages/asynchronous receipt exchange, wrong sequence disconnect, TLS WSS↔Unix ASMP payload/ID/sequence mapping and local cleanup. Boundary tests cover32-item queue closure,64 pending cap, owner adoption rejection, read-only receipt queries, mismatched media stop, >64 sequential accepted receipts,11-second observation expiry without receipt mutation, strict stats fields and concurrent stats access. Python loopback tests verify0600 output, no overwrite, quiet output and non-loopback rejection.

The media integration uses a fake Unix media peer; the unchanged real R3 manager is covered by its existing tests. The fake cloud is an isolated Go TLS server, not the concurrently implemented ECS service. These tests do not establish cross-implementation compatibility, PostgreSQL/Compose recovery, production domains/CA/network reachability, actual SMS delivery, real voice quality or real resource use.

R4_BUILD_EVIDENCE.json records ELF/hash/size, preserved R3/helper hashes and allocation evidence. The measured synthetic snapshot+messages operation allocated9917 B/op in97 allocations on the host over100 iterations. This is per-operation allocation, not retained heap or device RSS. Queue and tracking bounds are recorded separately. New RM500 RSS/CPU and device startup peaks have not been measured. Controller-provided free-space evidence must be rechecked by the controller at deployment; no partition cleanup was attempted here.

## Minimal controller deployment/bootstrap calls

Controller first follows the frozen idle deployment procedure, preserves identity/journal and R3 rollback, uploads the exact hash-verified R4 Agent and retains the unchanged accepted helper. Its existing invocation gains optional `--cloud-config <0700-config-dir>/cloud.json`; default is `<data-dir>/config/cloud.json`. Activation starts the outbound connection without restarting vendor services. Do not copy identity.json off-device.

Use an explicitly controller-created loopback forward to the protected control Unix socket, or run the script with `--endpoint unix:/run/airsim-v2/control.sock` where that socket is available. The script creates no ADB forward, calls no cloud admin API and prints no returned data. Input files must be0600 and output files must not already exist.

```sh
python3 module/airsim-agent/scripts/cloud_local.py --endpoint http://127.0.0.1:PORT --operation prepare --input /secure/prepare.json --output /secure/prepared.json
# Controller runs the ECS team's frozen issue-module procedure using these files.
python3 module/airsim-agent/scripts/cloud_local.py --endpoint http://127.0.0.1:PORT --operation activate --input /secure/activation.json --output /secure/activated.json
python3 module/airsim-agent/scripts/cloud_local.py --endpoint http://127.0.0.1:PORT --operation status --output /secure/cloud-status.json
python3 module/airsim-agent/scripts/cloud_local.py --endpoint http://127.0.0.1:PORT --operation media-stats --output /secure/cloud-media-stats.json
```

Remaining controller stages: cross-agent/server protocol integration and Compose validation, trusted ECS deployment, independent device TLS/network checks, provisioning, controlled cloud call/SMS/audio and failure recovery acceptance. This handoff does not start R5 or claim iOS/APNs,30-minute/100-session endurance or8kHz vendor-clock hardware validation.

## Final review: certificate lifetime bounds the live connection

Each connection validates the actual device leaf before discovery/dial and derives its context deadline from that leaf's NotAfter. The same context parents control readers/writer and this connection's media bridge. At expiry, cancellation closes control/media; final local status clears connected/connection_epoch and reports certificate_expired. A subsequent connection attempt with the expired leaf fails before discovery with certificate_invalid. No renewal or replacement identity is introduced.

A real isolated TLS/mTLS WebSocket test activates a roughly three-second certificate, completes hello/welcome while valid, keeps the session open, and verifies both Agent return and peer socket closure at the certificate deadline (within500ms), explicit expired status, and rejection of reuse. The test passed under race instrumentation; the full cloud-package race suite and full vet passed after the change. Final rebuilt ARM64 ELF/hash/size is recorded in R4_BUILD_EVIDENCE.json. No helper, device, cloud resource or git-index operation was performed.

## Controller-directed media ticket clock-skew fix

Agent's future-expiry plausibility check now accepts strictly0 < expires_at−now <=35 seconds, using one sampled now through an injectable helper. This is only the controller-frozen five-second tolerance for the device clock lagging ECS. It does not change expires_at, the media service's30-second ticket lifetime, pairing deadlines, or acceptance of already-expired tickets. UUID, ticket, ownership and busy checks are unchanged.

Deterministic nanosecond boundary tests cover a server-issued30-second ticket with aligned clocks, device clock behind1 second and exactly5 seconds,35 seconds plus1ns rejection,1ns remaining acceptance, exactly-current rejection and expired-by1ns rejection. They run through startMediaAt as well as the expiry helper: legal skew proceeds to media_owner rejection (without creating local media), whereas invalid expiry remains a protocol rejection. Cloud race, full race/vet, Go1.24.13 static ARM64 build and ELF inspection passed. Current artifact SHA/size is in R4_BUILD_EVIDENCE.json; this new build has not been deployed by this execution chat.

Read-only peer-source check: service/airsim/internal/control/media.go emits the same nine media_start fields, takes client/generation/call/boot/backend from its checked reservation, generates UTC expires_at with30 seconds, and uses wire.ID()/wire.Token() for lowercase UUIDv4 and32-byte lowercase hex. No other generation-format conflict was found. Agent still independently requires its in-memory accepted cloud dial/answer ownership binding and no active bridge; disagreement/missing state can yield media_owner/media_busy, which is a runtime qualification failure rather than malformed protocol. These conditions were reported only, not changed. No device/ECS/git-index operation was performed.
