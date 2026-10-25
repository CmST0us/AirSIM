# Compose operations — R4

Four resident services: `postgres`, `control`, `media`, `edge`. `migrate`, `admin`, and production `edge-storage-init` are one-shot tasks. The controller alone selects the host/domains and executes production deployment. These scripts never connect to ECS themselves.

## Configuration and images

- `compose.yaml`: local-only `airsim-r4-test`, loopback high port, synthetic CA, no automatic restart.
- `compose.production.yaml`: standard host 80/443, resident services `restart: unless-stopped`; one-shot tasks `restart: no`.
- Official source indexes are pinned in `images.lock`. Production supports `AIRSIM_CADDY_IMAGE`, `AIRSIM_POSTGRES_IMAGE`, `AIRSIM_BUSINESS_IMAGE` overrides and `pull_policy: never`.
- An offline override is an **ECS-verified content-addressed image ID**. Registry index digest, architecture child manifest, image config, archive checksum/manifest and runtime ID are different identifiers. The controller records and verifies their chain; never relabel a config/runtime ID as a registry digest. No arbitrary registry mirror is selected here.
- Business image builds with the pinned Go builder and runs from scratch. Build explicit linux/amd64 artifacts for ECS. Save/load transport is controller-owned.

Copy `.env.example` to an external non-secret deployment configuration and export its values. Never place bearer tokens, database passwords or CA keys in environment variables. Set `AIRSIM_BUSINESS_IMAGE` to the verified immutable reference before using `scripts/production-compose.sh`.

Create a new deployment directory and external protected directory (0700, owner 65532:65532). Generate `database-password` there using a cryptographically random generator, file mode 0600. Create the `tls/` subdirectory; public production certificates are managed in the Caddy volume, not copied from local test fixtures. All business and edge processes run as 65532:65532. The device CA private key is only mounted in admin.

API and device hostnames must differ. `AIRSIM_MEDIA_ORIGIN` may equal the API origin, or use a third hostname. The production renderer directs `/v2/media` to media, the discovery/module APIs to control, and only `/v2/device/control` through the separate device mTLS host. The edge has its own ordinary ingress/ACME-egress network; database/control/media networks remain internal with no published ports.

## Initialize on the authorized host

After loading/validating images and exporting configuration, run the following from this directory. These are instructions, not evidence that ECS deployment has occurred.

```sh
scripts/production-compose.sh config --quiet
scripts/production-compose.sh up -d postgres
scripts/production-compose.sh run -T --interactive=false --rm migrate </dev/null
scripts/production-compose.sh run -T --interactive=false --rm admin --operation init --secrets-dir /protected/identity </dev/null
```

`init` creates `identity/identity.json`, the five-year device CA, independent edge/media bearers and command-HMAC key. It refuses an existing identity directory. Read only the public `server_id` from `identity.json` into `AIRSIM_SERVER_ID`; never dump the directory. Initialization failure must be inspected rather than deleting existing identity material.

```sh
python3 scripts/render-production-edge.py
chown 65532:65532 "$AIRSIM_SECRET_DIR/Caddyfile"
scripts/production-compose.sh run -T --interactive=false --rm edge-storage-init </dev/null
scripts/production-compose.sh run -T --interactive=false --rm --no-deps --entrypoint /bin/sh edge -ec 'test -w /data; test -w /config' </dev/null
scripts/production-compose.sh run -T --interactive=false --rm --no-deps edge caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile </dev/null
scripts/production-compose.sh up -d control media edge
```

The explicit root storage initializer mounts **only this project's** `tls-state` and `edge-config` named volumes, applies 65532:65532 ownership and 0700 mode to the two top-level mount directories only and checks both. It does not recurse into, chown, or rewrite existing certificates/files; Caddy creates their contents as uid 65532. This makes repeat initialization safe without DAC traversal capabilities. It has no network or secrets and exits. Edge remains nonroot/read-only/no-new-privileges, with `cap_drop: ALL` and the controller-approved sole `NET_BIND_SERVICE` capability. The fixed official Caddy executable carries that file capability and fails to execute when it is absent. Do not broaden capabilities.

Healthchecks distinguish process liveness (`/healthz`) from database schema readiness (`/readyz`); edge health uses an actual verified TLS request. PostgreSQL health precedes migration, then control health, then media/edge. Caddy obtains publicly trusted TLS only after the controller has provided working DNS and public ACME reachability. Local fixture certificates do not establish that production prerequisite.

## Controlled test-client and module provisioning

```sh
scripts/production-compose.sh run -T --interactive=false --rm admin --operation issue-client --output /protected/client-test.json </dev/null
scripts/production-compose.sh run -T --interactive=false --rm admin --operation revoke-client --client-id '<installation UUID>' </dev/null
```

The output file is 0600 and must not already exist. Token validity defaults to 60 minutes; `--client-ttl` accepts 1h through 720h (30 days). There is no automatic refresh or interactive login. Transfer it only through an authorized protected channel, never a URL, terminal output or ordinary logs.

The controller calls the Agent's local Unix `cloud/prepare` endpoint using the frozen request. Preserve the exact request and response as 0600 files under the protected directory. Do not copy the device private key; the response contains public key/CSR/proof only.

```sh
scripts/production-compose.sh run -T --interactive=false --rm admin --operation issue-module \
 --secrets-dir /protected/identity \
 --request /protected/prepare-request.json \
 --response /protected/prepare-response.json \
 --output /protected/activation-bundle.json </dev/null
```

Issuance verifies proof, CSR/public key/SAN, pending expiry and exact configured server/origins. Send only the resulting bundle to the Agent's local activation endpoint. A retry uses the same request/response and a new output filename; no private device material is exported. A distinct reissuance/automatic renewal workflow is outside R4. Device certificates are 30-day ClientAuth-only; live control sockets also close at certificate expiration.

## Backup, restore, upgrade and rollback

Before upgrade, record the current runtime IDs, schema, deployment parameters and active-call state. Wait for idle and stop new acceptance under controller coordination. Media restart interrupts live audio; do not claim seamless recovery. Retain prior image archives and protected credentials.

Back up PostgreSQL with `pg_dump -Fc` into a newly created 0600 external file, and separately protect the deployment identity, device CA, service secrets and Caddy state. Never copy a real module's identity to another module. Restore first into an isolated database or dedicated recovery host with no connected control service. Compare content before switching any live service.

`scripts/backup-restore-test.sh` is intentionally restricted to the local `airsim-r4-test` project. It restores to a separately named `airsim_r4_restore*` database and compares every R4 table without printing rows, token hashes or certificates. It is not a production restore command. No provided wrapper supports `down -v` on production.

Run migrations explicitly before starting a new control version. An unsupported higher schema fails closed. Image rollback is only valid if the controller has checked compatibility with the retained database; otherwise restore the corresponding isolated verified backup under an explicit recovery plan. Never reset a production volume to make a migration pass.

All one-shot `docker compose run` commands use `-T --interactive=false`. Remote script invocations also redirect stdin from `/dev/null` so they cannot consume subsequent commands.


## R7 APNs

The control process sends APNs over HTTP/2 on its dedicated `push_egress` network. No control ports are published. The device, media and command contracts remain unchanged. Discovery reports `airsim-v2-r7`; all four APNs settings empty disables push, while partial configuration or an invalid/restricted-file permission failure prevents startup.

Set `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_BUNDLE_ID` for the signed iPhone App. Set `AIRSIM_APNS_KEY_PATH` to the existing external `.p8` file. The production wrapper then includes `compose.apns.yaml`, mounting that file read-only as `APNS_KEY_FILE=/run/secrets/apns.p8`. The file must be readable by control UID 65532 with no group/other permissions (normally owner 65532, mode 0600); parent directories must allow the container runtime to mount it. Never place the key in build context, Git, environment values or logs. A missing host file is rejected instead of being created as a directory. For direct Compose usage, include the same overlay explicitly. Keep these settings on subsequent control recreation.

Registration accepts `sandbox` or `production` per installation; it must match the signed App entitlement. Topic is the configured main Bundle ID (`.voip` for incoming calls). APNs transport requires outbound DNS and TLS to Apple's sandbox/production provider. A configured provider and successful mock tests do not establish real APNs delivery or lock-screen wakeup.

`PUT /v2/push/registration` authenticates the existing client Bearer and subscribes that installation to one owned module. Token updates reuse its registration ID; changing subscription domain requires DELETE followed by a new ID. DELETE matches both installation and registration ID, so delayed cleanup cannot delete a newer registration. Responses never contain tokens. Client expiry/revocation immediately excludes delivery and hourly cleanup removes obsolete subscriptions and their delivery metadata. CallKit identities remain for 31 days, longer than the maximum client lifetime.

Call notifications require an online device and a snapshot no older than 8 seconds or more than 3 seconds in the future. Each attempt rechecks subscription, client, module and current call. Payload validity is 30 seconds; APNs expiration is zero. Success is persisted per registration/call domain; transient failures get at most two short retries. Network requests run outside the control lock. SMS uses the alert token and a fixed notification without sender/body, only for incoming messages observed after registration. Token refresh preserves the registration start time. No private APNs credentials are needed for the local mock test suite.

Migration advances schema 1 to 2 in the existing transaction/advisory lock. Back up before an authorized production upgrade. The older R4 binary requires schema 1; rollback therefore requires the matching pre-upgrade database backup, not only replacing the image.
