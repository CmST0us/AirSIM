# R8 pairing proof

2026-10-27. Implements the Agent portion of [R8 pairing](../protocol/v2/R8_PAIRING.md).

## Implemented

- `GET /v2/local/pairing` returns only module public identity, platform profile, validated server binding, connection state and certificate expiry. Unconfigured, invalid and expired configurations fail without exposing historical bodies or private material.
- `POST /v2/local/pairing/authorize` strictly decodes the requested fields and signs the R8 domain-separated message with the existing Ed25519 identity. The proof binds request, server, module, nonce, expiry and the hash of the browser polling secret.
- Discovery accepts the existing R4.1 profile and the R7 profile used by the current ECS service, with optional R8 capability fields. Older discovery responses remain valid.

## Verified

- `go test -race ./...` passed, including pairing field, timestamp, service/module binding, proof-domain, private-material exclusion, strict HTTP, unavailable configuration and discovery compatibility cases.
- The interface is served before existing cloud routes only on the protected Unix socket. No TCP listener, cloud credential, private key or seed is returned.

## Not performed

- No RM500 deployment, USB/WebUSB execution, production pairing, firmware install, vendor-service restart or cloud control acceptance is claimed by the unit tests.
- Persistent boot installation and OTA remain outside R8. The current deployment helper is a development mechanism.
