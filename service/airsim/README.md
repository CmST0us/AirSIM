# AirSIM v2 Go Relay

As of the 2026-11-02 change, `call.dial` and `sms.send` accept `+?[0-9]{6,15}`, including six-digit short numbers. Leading zeroes and an optional `+` are forwarded unchanged. Control and the web Engine packages were deployed through Workbench as `shortnumber-20261102`; media, edge and PostgreSQL were not restarted. Deploy matching App and Agent builds: older components still reject six-digit numbers. Physical EG25 installation is user-managed and carrier calls remain untested; see [deployment evidence](../../docs/SHORT_NUMBER_UPDATE.md).

Push notifications add installation-scoped APNs registration and incoming-call/SMS notifications to the R4 control service. Public contracts are [`R4`](../../protocol/v2/R4.md) and the [`CallKit contract`](../../protocol/v2/CALLKIT.md). Discovery advertises `airsim-v2-callkit`; `apns` is enabled only with a complete provider configuration. Interactive login, Watch v2, OTA and v1 compatibility are not implemented; administrator clients remain temporary, while paired clients are revocable permanent device sessions. Only the main controller deploys to ECS and performs physical-module tests.

Call media is a WebRTC audio connection between the App and the module ([`WEBRTC`](../../protocol/v2/WEBRTC.md)). Control creates media sessions under the call reservation, issues per-session TURN credentials, forwards the App's complete offer once in `media_start` and returns the Agent's `media_answer`; it never decodes media or holds SRTP keys. Session creation requires `codec: "opus"`; Agents whose hello declares `lc3` or nothing keep control access but media creation returns `409 media_unavailable`. Offer failures return `502 media_unavailable` or `504 media_timeout`, which leave call control state intact. Update App, Agent, control and media together in an idle window.

The media service logs one line per TURN allocation and release with the session ID, role and transport; it logs no credentials or audio. Control logs `media_failed` with a fixed reason when an offer ends without an answer.

USB local authorization uses [`USB_LOCAL.md`](../../protocol/v2/USB_LOCAL.md). Authenticated clients request `POST /v2/modules/{id}/usb-authorization` with `{}` through the existing ownership and module-scope checks. Only an online Agent advertising `usb_local: true` receives `usb_authorize`; the server waits up to four seconds on that control connection and returns the validated authorization with `Cache-Control: no-store`. Disconnects and cancelled requests clear the waiter. Local tokens are neither persisted nor logged. Pairing replacement immediately synchronizes `usb_revoke`; a five-second database scan also covers administrator CLI revocation and expired sessions. Online Agents receive each revoked client once per connection, including after reconnect. Offline modules enforce the existing authorization expiry, at most 24 hours. Existing Agents without the capability continue to use cloud transport. USB hardware and local calling/media acceptance remain separate from these server tests.

Agent snapshots may include optional, nullable `signal`: `{available, observed_at, rssi, dbm}`. Available samples require a UTC RFC3339 timestamp, CSQ RSSI 0–31 and `dbm = -113 + 2 × rssi`; unavailable samples carry null RSSI/dBm and an optional timestamp. The Agent polls every ten seconds and expires samples after thirty seconds. ECS validates and forwards this field in snapshots and every online module's `GET /v2/modules` entry. Offline responses omit cached signal measurements. Agents without the field remain accepted. Update App decoders to accept the optional field before publishing server/Agent signal support: older strict v2 clients reject newly populated fields. Worker v2 must implement the same contract when scheduled.

On 2026-10-31, the control service and EG25 Agent were updated and the paired iPad passed a read-only UI test of live signal delivery through ECS. The App displayed three bars; the module's subsequent sample was CSQ 18 / −77 dBm. Media and database containers were unchanged. Agent, server and App signal tests cover unknown, expired and offline readings; physical USB signal-display acceptance remains pending.

Authenticated Agent hello messages may include `platform`. Pairing lookup displays RM500U or EG25 QDC507 from this live metadata; absent or unknown values use AirSIM. This field does not change ownership, phone scope or media framing.

Call ownership reservations survive connection-only reconnects. A validated snapshot with control ready, calls available and valid boot/backend IDs releases only that module's reservations from an older Agent/backend generation; command history and current-generation ownership remain intact. Cleanup requires an observation no older than eight seconds and no more than three seconds ahead. Stale, invalid or unavailable snapshots cannot release ownership. A new incoming call can then acquire its own reservation after an Agent restart or backend reset.

Device pairing adds the web flow and permanent client session contract in [`PAIRING.md`](../../protocol/v2/PAIRING.md). New paired clients are scoped to one module, and a module accepts only one active paired phone until that client is revoked. Administrator-issued clients retain the existing owner-wide R4 behavior. The browser build is served from the same HTTPS API origin through the Compose edge.

- `cmd/airsim-server`: PostgreSQL-backed control, device authentication, directed commands, ownership and media orchestration.
- `cmd/airsim-media`: TURN relay on the host network (UDP/TCP 3478, UDP relay ports 49160–49359); verifies stateless credentials signed with the TURN secret; no database or CA private key.
- `cmd/airsim-migrate`: versioned SQL under `migrations/`, guarded by a PostgreSQL advisory lock.
- `cmd/airsim-admin`: protected shell-only init, test-client issue/revoke and proof/CSR-based module issuance.
- `cmd/airsim-test-setup`: synthetic local test fixtures; excluded from the production image.
- `integration/`: opt-in real Compose TLS/mTLS tests. Without an explicit fixture directory these tests skip.

Go 1.24.13; fixed websocket 1.8.15, pgx/v5 5.7.6 and Pion TURN v4.1.1. Runtime binaries are CGO-free. No raw commands, phone numbers, message bodies or PCM are stored in PostgreSQL. Test tokens are stored as SHA-256 hashes; command idempotency uses keyed HMAC.

```sh
go test -race ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o dist/linux-amd64/ ./cmd/airsim-server ./cmd/airsim-media ./cmd/airsim-migrate ./cmd/airsim-admin
```

For isolated test setup, use a fresh external secrets directory and explicit Go path:

```sh
AIRSIM_SECRET_DIR=/absolute/new/external/test-directory \
GO=/absolute/path/to/go \
./deploy/compose/scripts/test-stack.sh
AIRSIM_INTEGRATION_DIR=/absolute/new/external/test-directory go test -race -count=1 -v ./integration
```

The stack script only uses project `airsim-r4-test` and a loopback high port. It does not install its CA into system trust. It fails rather than overwriting an existing fixture directory. Runtime files, tokens and private keys are never printed. Database migration schema 5 keeps the newest active phone per module, revokes older duplicate phone records and clears paired-session expiry fields. Schema 6 records a module-holder reset intent and atomically replaces the old phone when the new phone claims its code.

Deployment prerequisites, administrator operations and rollback are in [Compose operations](deploy/compose/README.md). Current executed checks and remaining production boundaries are in [R4 evidence](R4_TESTING.md).

Push notification database migration adds push registrations, persistent CallKit identities and delivery deduplication without replacing existing records. Administrator-issued clients default to one hour and accept `--client-ttl 1h` through `720h`. Push provider keys remain in a restricted external file. Setup and mock-only validation are documented in [Compose operations](deploy/compose/README.md) and [push testing](PUSH_TESTING.md).

APNs supports either the existing shared key or a complete Sandbox/Production key pair. Environment-scoped keys are selected per registered installation, with separate JWT caches and HTTP clients; see [Compose APNs configuration](deploy/compose/README.md#apns).
