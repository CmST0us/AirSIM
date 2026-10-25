# AirSIM v2 Go Relay

R7 adds installation-scoped APNs registration and incoming-call/SMS notifications to the R4 control and media relay. Public contracts are [`R4`](../../protocol/v2/R4.md) and [`R7 M2`](../../protocol/v2/R7.md). Discovery advertises `airsim-v2-r7`; `apns` is enabled only with a complete provider configuration. Interactive login, automatic token renewal, Watch v2, OTA and v1 compatibility are not implemented. Only the main controller deploys to ECS and performs physical-module tests.

- `cmd/airsim-server`: PostgreSQL-backed control, device authentication, directed commands, ownership and media orchestration.
- `cmd/airsim-media`: independent ephemeral PCM relay; no database or CA private key.
- `cmd/airsim-migrate`: versioned SQL under `migrations/`, guarded by a PostgreSQL advisory lock.
- `cmd/airsim-admin`: protected shell-only init, test-client issue/revoke and proof/CSR-based module issuance.
- `cmd/airsim-test-setup`: synthetic local test fixtures; excluded from the production image.
- `integration/`: opt-in real Compose TLS/mTLS tests. Without an explicit fixture directory these tests skip.

Go 1.24.13; fixed websocket 1.8.15 and pgx/v5 5.7.6. Runtime binaries are CGO-free. No raw commands, phone numbers, message bodies or PCM are stored in PostgreSQL. Test tokens are stored as SHA-256 hashes; command idempotency uses keyed HMAC.

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

The stack script only uses project `airsim-r4-test` and a loopback high port. It does not install its CA into system trust. It fails rather than overwriting an existing fixture directory. Runtime files, tokens and private keys are never printed.

Deployment prerequisites, administrator operations and rollback are in [Compose operations](deploy/compose/README.md). Current executed checks and remaining production boundaries are in [R4 evidence](R4_TESTING.md).

R7 database migration adds push registrations, persistent CallKit identities and delivery deduplication without replacing existing records. Administrator-issued clients default to one hour and accept `--client-ttl 1h` through `720h`. Push provider keys remain in a restricted external file. Setup and mock-only validation are documented in [Compose operations](deploy/compose/README.md) and [R7 testing](R7_TESTING.md).
