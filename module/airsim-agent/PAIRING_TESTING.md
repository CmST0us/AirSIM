# Device pairing proof

2026-10-27. Implements the Agent portion of [pairing](../../protocol/v2/PAIRING.md).

## Implemented

- `GET /v2/local/pairing` returns only module public identity, platform profile, validated server binding, connection state and certificate expiry. Unconfigured, invalid and expired configurations fail without exposing historical bodies or private material.
- `POST /v2/local/pairing/authorize` strictly decodes the requested fields and signs the pairing domain-separated message with the existing Ed25519 identity. The proof binds request, server, module, nonce, expiry and the hash of the browser polling secret.
- Discovery accepts the legacy R4.1 profile and the CallKit profile used by the current ECS service, with optional pairing capability fields. Unknown profiles remain rejected.

## Verified

- `go test -race ./...` passed, including pairing field, timestamp, service/module binding, proof-domain, private-material exclusion, strict HTTP, unavailable configuration and discovery compatibility cases.
- The interface is served before existing cloud routes only on the protected Unix socket. No TCP listener, cloud credential, private key or seed is returned.

## Not performed

- No RM500 deployment, USB/WebUSB execution, production pairing, firmware install, vendor-service restart or cloud control acceptance is claimed by the unit tests.
- Persistent boot installation and OTA remain outside pairing scope. The current deployment helper is a development mechanism.
