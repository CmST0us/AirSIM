# Push notification server verification

2026-10-25. Scope: `service/airsim`; contract: [APNs extension](../../protocol/v2/APNS_EXTENSION.md). No production deployment or real APNs requests were performed.

## Current scope and deployment status

As confirmed by the controller on 2026-10-25, this delivery and acceptance cover v2 compatibility with the original five App views and CallKit system-call integration. APNs credentials, PushKit offline wakeup and SMS push notifications are outside this phase's delivery and acceptance scope. They are not prerequisites for CallKit integration.

Commit `411bf38` retains the server-side APNs preparation code and the local verification results below. The provider remains disabled. According to the controller, production remains on R4.1, which supports the current App/CallKit integration; the system-call schema 2 and discovery profile upgrade have not been deployed.

The Linux amd64 image `airsim-business:push-411bf3834407-amd64` was built locally with image ID `sha256:6491661c798a57413c539c40a973b10b7ebba2da810792945ba835b2e4c81d64`. The controller reports that the uploaded image is staged only. Image build and upload do not establish deployment, real push delivery or CallKit acceptance. The tests below document the retained server preparation work; they do not establish iOS view compatibility or system-call behavior on a physical device.

## Executed

- `go test -race ./...` with Go 1.24.13 and an explicitly supplied empty local PostgreSQL 17.11 database. `TestPushDatabaseContract` executed against PostgreSQL; the separate opt-in R4 Compose integration suite was not enabled.
- `go vet ./...` and CGO-free Linux amd64 builds of control, media, admin and migrate.
- Provider tests use generated temporary test keys and local transports only. They verify P-256 ES256 JWT signatures, sandbox/production destination selection, VoIP/alert headers, expiration zero, actual HTTP/2 negotiation over local TLS, disabled/partial/invalid configuration, restricted key permissions, and permanent/transient/token-invalid responses.
- Database tests seed schema 1 with identity, client, module, command and reservation records, migrate to schema 2 twice, and verify those rows remain. Tests cover client authorization, module ownership, Bundle ID validation, required JSON fields, registration replacement rejection, stale DELETE safety, payload identity, persistent CallKit UUID, duplicate snapshots, reconnect/service-object restart, historical SMS exclusion, new SMS deduplication and body privacy, ended/offline/stale/future calls, client expiry/revocation, bounded retries and invalid-token feedback after token refresh.
- Client TTL tests reject values outside 1h–720h and verify a real 30-day issuance through the database.
- Local and production Compose configuration with the APNs overlay was rendered using synthetic settings. Control has no published ports; `push_egress` provides egress, and the key bind is read-only with host-path creation disabled. Production Caddy rendering includes `/v2/push/registration` and retains device/media routes.
- Scoped whitespace, documentation link and sensitive-material checks.

## Reproduce database/provider tests

Use a fresh, disposable local database. The database test refuses an existing schema and does not reset user data. Commands below create only the named local test container; port 18543 must be available.

```sh
docker run -d --name airsim-push-test \
  -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=airsim_test \
  -p 127.0.0.1:18543:5432 \
  postgres:17.11-alpine3.24@sha256:eee6c6e1b0894fa4fe0075eb054af9fd1cf39a35321c2d4110626cfe506411fb
# Wait until this succeeds before invoking Go tests.
docker exec airsim-push-test pg_isready -U postgres -d airsim_test
AIRSIM_PUSH_TEST_DATABASE_URL='postgres://postgres@127.0.0.1:18543/airsim_test?sslmode=disable' \
  go test -race ./...
docker rm -fv airsim-push-test
```

These commands run from `service/airsim` and use `go` from the configured Go 1.24.13 toolchain. No APNs account or real key is required. For another run, create another empty database or recreate this disposable container.

## Limitations

APNs acceptance is not proof of handset delivery. No real APNs credentials were read, production migrations applied, iOS signing changed, or lock-screen/cold-start behavior verified by these tests. The iOS executor owns client-side contract and CallKit tests; full device acceptance belongs to the controller.

Delivery success is recorded after APNs responds. A process or database failure between APNs acceptance and that write leaves an uncertain delivery outcome; persistent CallKit UUID remains stable for client-side duplicate handling. This is not an exactly-once delivery guarantee.

Schema 2 is an additive upgrade. The R4 binary requires schema 1, so an authorized rollback must use the matching pre-upgrade database backup with that binary.
