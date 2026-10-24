# R4 server delivery evidence — local integration milestone

2026-10-24. Scope is exclusively `service/airsim/`. This chat did not stage/commit, deploy to ECS, access Cloudflare, touch a physical module, place calls, send real SMS, or record PCM. The controller owns production deployment and real-content acceptance.

## Implemented

- Go control/media services; PostgreSQL schema 1, explicit advisory-locked migration; shell-only administrator init, test-client issue/revoke and proof/CSR module issuance.
- Device CA and endpoint-bound provisioning, independent edge/media/HMAC secrets, token hashes, mTLS leaf/public-key/serial validation and live certificate-expiry shutdown.
- Strict control JSON, sequence/connection epochs, per-module in-memory snapshots/inbox, persistent directed-command HMAC/idempotency, reservations, reconnect receipt queries without command redispatch.
- Actual R2 receipt semantics: prepared/dispatched → dispatched; accepted/observed/failed/expired → completed; outcome_unknown remains outcome_unknown. The original receipt is retained. Server completed does not mean a connected call or delivered SMS. Fabricated R2 completed/rejected are rejected. A failed/expired reservation-creating command releases only its own reservation; unknown/null/accepted never do.
- Independent media one-use tickets, ASMP checks, five-frame queues, bounded writes, pair/frame/lease deadlines and failure cleanup. Control media I/O occurs outside its global mutex; at most 32 workers, no overlapping job for one session. Late results cannot revive closed sessions. Media request history is capped at 10,000 per control lifetime, preserving old ID semantics and clearing plaintext tickets on closure.
- Fixed image references, scratch business runtime, native builder with TARGETARCH cross-compilation, local-only test Compose and production Compose for 80/443. Production supports shared API/media or independent media hostnames, verified offline runtime image IDs with pull_policy never, and explicit nonroot-writable Caddy volume initialization.

## Executed checks

Toolchain: Go 1.24.13. Host Docker 29.4.0 / Compose 5.1.2. Official standalone Compose 2.26.1 was downloaded with its published SHA-256 verification and used to parse the production configuration and execute isolated volume-permission checks.

- `go test -race ./...` and `go vet ./...` passed. Without `AIRSIM_INTEGRATION_DIR`, the integration package explicitly skips; that default green result is not counted as integration evidence.
- Explicit `AIRSIM_INTEGRATION_DIR=/tmp/airsim-r4-test-20261024 go test -race -count=1 -v ./integration` passed against the real isolated Compose stack, including:
  - verified TLS/mTLS; missing certificate, unknown but CA-signed module, bare token and forged API identity headers rejected;
  - two modules and two clients; target routing, cross-module epoch rejection, command replay/conflict and ownership exclusion;
  - real R2 accepted SMS and dial receipts, accepted→observed answer updates, call association and active-snapshot media eligibility;
  - failed/expired dial release, unknown dial reservation retention, failed hangup retaining the original owner;
  - offline no-queue behavior, control container restart, persisted unknown receipt, reconnect receipt-query recovery without redispatch;
  - connected device short-lived certificate expiration closes WSS;
  - media pairing and bidirectional synthetic ASMP frames, explicit revoke, media container restart, old-ticket rejection and new-session recovery.
- Unit/race checks cover strict nested fields/duplicates/null handling, frame/session/direction/replay validation, internal authentication, ticket reuse, wrong-epoch renew, lease expiry, 32 active media-session limit, slow-consumer bounded queues, media I/O isolation from another module's heartbeat/snapshot/command queue, stale-renew non-revival, and the 10,000-entry history cap.
- Real PostgreSQL dump/restore into separate `airsim_r4_restore*` databases: schema_version, identity, clients, modules, provisions, commands and reservations compared equal by complete row-content fingerprints. Rows, tokens and certificates were not printed. No control service connects to restored databases.
- Production Caddy shared-host and separate-media configurations both adapted successfully. Compose 2.26.1 parsed the production file. The root one-shot initializer and subsequent uid 65532 checks established ownership/mode 65532:65532:0700 and writable `/data` and `/config` on dedicated test volumes.
- Linux/amd64 static binaries and a linux/amd64 business image were built. Final image metadata and build-input fingerprints are in `R4_BUILD_EVIDENCE.json`.

## Resolved findings retained for audit

Initial edge startup failed because official Caddy carries `cap_net_bind_service=ep`. The controller approved the sole NET_BIND_SERVICE capability after cap_drop ALL; nonroot/read-only/no-new-privileges remain. A normal network dedicated to edge provides port publication and production ACME egress; internal services publish no ports.

The first fake receipt test used observed and did not catch missing accepted handling. The controller identified this; mapping and fixtures were corrected to the actual R2 journal/wire fields, with explicit accepted/observed/failure cases. The accepted-compatible final integration supersedes that early result.

## Protected local test resources

External synthetic credentials: `/tmp/airsim-r4-test-20261024` (0700, files 0600). Never print or commit this directory. Its test CA is not installed into system trust. Local containers and volumes belong only to `airsim-r4-test`; two additional dedicated volumes check ACME permissions. Test certificates/tokens have short validity; regenerate fixtures rather than treating them as deployment credentials.

## Not claimed

No ECS business deployment, public ACME issuance, real Agent-to-ECS interoperability, real carrier call/SMS, 75-second content listening, iOS/Watch/APNs, interactive login, certificate renewal, long-duration qualification or production backup recovery has been performed by this chat. The configured production origins (`airsim.eric3u.cc`, `device.airsim.eric3u.cc`) were supplied and managed by the controller. Local synthetic frame success is not real audio-content acceptance.

The controller must review and stage the service directory for the milestone commit, then deploy and perform the remaining real-device acceptance.
