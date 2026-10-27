# Device pairing and permanent sessions

2026-10-27. Implements the service portion of [pairing](../../protocol/v2/PAIRING.md).

## Verified

- Service schema 5 returns schema 3 claim responses with null access/refresh expiry, keeps paired tokens valid after their former timestamp, and returns schema 2 refresh compatibility responses without persisting an expiry. Schema 6 persists the module-holder reset intent and revokes the old phone only inside the replacement claim transaction.
- `go test -race ./...` and `go vet ./...` pass.
- The pairing database test covers challenge approval, code lookup, claim, exact retry, competing claim rejection, second-phone rejection, reset confirmation, replacement claim, old-token revocation, one-module directory scope, permanent token validation, access-token rotation and refresh revocation.
- The isolated Compose TLS/mTLS stack passed all existing control/media tests plus pairing-route protection: two modules, two clients, persistent idempotency, stale epochs, offline rejection, one-use media tickets, duplex media, reconnect and restart recovery.
- The API origin served the built pairing page with `Content-Security-Policy`, `Permissions-Policy: usb=(self)`, `no-store` and `nosniff`. API headers cannot impersonate device identity.
- Caddy validated the production static/API/device/media configuration.

## Boundaries

- The tests use synthetic module proofs and PostgreSQL. Physical RM500/WebUSB pairing and production ECS deployment are recorded separately.
- Production migration keeps one newest active phone per module and revokes older duplicate phone records. Deploy only after confirming the retained device and recording revoked IDs.
- APNs remains disabled. Watch v2, bare-module installation and OTA are outside pairing scope.
