# iOS AirSIM device pairing

2026-10-27. Implements the App side of the [device-pairing contract](../protocol/v2/PAIRING.md) inside the existing v2 settings and five-tab App.

## Behavior

- The normal user flow is “添加设备”, eight-digit code lookup, explicit device confirmation, then claim. The UI does not request a server address, JSON file or protocol version.
- The old administrator import remains available under “其他方式” for existing temporary R4 deployments; a newly paired session does not depend on it.
- A pending claim, installation ID and refresh token are stored in the Keychain with `AfterFirstUnlockThisDeviceOnly`. A lost claim response retries the same operation instead of creating another device session.
- A successful paired session keeps the installation ID and module scope stable. The revocable device credential and its access token have no service-side expiry, so a phone that opens AirSIM after a long absence connects without refreshing.
- Each module accepts one active paired phone. A second phone receives `module_already_paired`; revoke the current client before pairing a replacement.
- The person who physically holds the module has reset authority. The pairing page can create a replacement challenge after an explicit warning; the old phone remains active until the new phone claims the generated code, then both records are replaced atomically.
- Legacy schema-1 temporary credentials retain their original expiry and manual-import behavior.

## Verification

- Xcode simulator `build-for-testing` succeeds with the deployment pairing origin injected through `AIRSIM_V2_PAIRING_ORIGIN`.
- Unit coverage includes lost-claim retry identity, complete session commit, long-dormant access-token recovery, single refresh on 401, token replacement and stable installation identity.
- Focused CloudV2 tests pass, including lost-claim retry, 401 refresh, legacy near-expiry compatibility, identity/origin checks and background connection cancellation.
- The complete UI flow passes on a clean iPhone 18 Pro simulator: existing Settings → 添加设备 → eight-digit code → RM500 confirmation → claim → automatic-renewal status → module row. The simulator uses an in-process pairing store because its Keychain is unavailable.
- Real Chrome WebUSB selected the attached RM500, verified its module identity and Ed25519 proof, and displayed the five-minute code. The web page reached “设备已连接”.
- The production ECS records the paired client as `connected`, non-revoked, and scoped to the same module as the pairing request.
- On 2026-10-27 the schema-5 service kept the current simulator installation, revoked four historical duplicate phone clients and removed paired-session expiry. The iOS client reconnected through the existing permanent credential, the module returned online with control, telephony and audio capabilities, and a second pairing request correctly returned `409 module_already_paired`. Deployment and rollback details are in [permanent-pairing deployment evidence](IOS_AIRSIM_PERMANENT_PAIRING_DEPLOYMENT.json).
- Schema 6 is deployed with the module-holder reset page. A live replacement challenge was authorized by the RM500, produced a valid phone lookup while the old client remained active, and was cancelled without changing the current phone. The claim-time atomic replacement is covered by the isolated PostgreSQL test; deployment details are in [pairing-reset deployment evidence](IOS_AIRSIM_PAIRING_RESET_DEPLOYMENT.json).

## Boundary

- Physical-iPhone Keychain persistence and long-running refresh across App relaunches have not been repeated as part of this pairing closeout.
- The schema-4 service is live, but the updated iOS build has not yet been installed on a physical iPhone for this deployment record.
- The API and pairing page use the Cloudflare-proxied `https://airsim.eric3u.cc` hostname. The device hostname remains DNS-only so the RM500 mTLS path is not terminated at the Cloudflare edge.
- Tapping “添加设备” requires a build with `AIRSIM_V2_PAIRING_ORIGIN` configured to the deployment HTTPS origin. The repository default intentionally contains no maintainer origin.
