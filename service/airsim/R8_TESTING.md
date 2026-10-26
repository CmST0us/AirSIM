# R8 pairing and renewable sessions

2026-10-27. Implements the service portion of [R8 pairing](../../protocol/v2/R8_PAIRING.md).

## Verified

- `go test -race ./...` and `go vet ./...` passed.
- An isolated PostgreSQL run passed `TestPairingDatabaseScopeClaimRefreshAndRevoke`: challenge approval, code lookup, claim, exact retry, competing claim rejection, one-module directory scope, access-token rotation and refresh revocation.
- The isolated Compose TLS/mTLS stack passed all existing control/media tests plus pairing-route protection: two modules, two clients, persistent idempotency, stale epochs, offline rejection, one-use media tickets, duplex media, reconnect and restart recovery.
- The API origin served the built pairing page with `Content-Security-Policy`, `Permissions-Policy: usb=(self)`, `no-store` and `nosniff`. API headers cannot impersonate device identity.
- Caddy validated the production static/API/device/media configuration.

## Boundaries

- The tests use synthetic module proofs and PostgreSQL. Physical RM500/WebUSB pairing and production ECS deployment are recorded separately.
- APNs remains disabled. Watch v2, bare-module installation and OTA are outside R8.
