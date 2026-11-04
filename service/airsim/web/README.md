# AirSIM pairing web

TypeScript/Vite pairing page for the first device connection. The approved local design remains in `design/pairing-web/`; `tests/visual/reference.png` preserves its visual baseline.

```sh
npm ci
npm test
npm run build
npm run dev -- --port 4174 --strictPort
```

Node 22.12+ is required by the pinned toolchain. Run commands from this directory.

## Integration

An up-to-date EG25 offers **短信收件诊断** before pairing. It uses the existing protected Agent Unix socket to collect storage capacities, CNMI settings and poll counters, with no message contents, numbers or credentials. Collection is serialized with the Agent AT manager, continues independently of a cancelled browser request, and is cached for 15 seconds. The frontend exports only allowlisted fields. This does not reset pairing or delete SMS; the Engine's automatic full-store retention is described in the [receive investigation](../../../docs/EG25_SMS_RECEIVE_INVESTIGATION.md).

`src/adapter.ts` composes the production WebUSB/ADB transport in `src/transport/webusb.ts`. It uses the system device picker, connects only to the user-selected module, performs the local Ed25519 proof through the protected Agent socket, and then calls the same-origin `/v2/pairing` service. Unsupported browsers and mobile devices show their own instructions. There is no production mock or fixture query parameter.

The picker includes factory EG25 USB IDs as well as ADB interfaces. On macOS, `eg25-bootstrap.ts` talks directly to the QDC507 USB AT bulk interface; no system serial device or host ADB server is required. Read-only inspection verifies the firmware before offering **开启 ADB 并重启**. Explicit confirmation enables legacy QDC507 ADB authorization, preserves the actual VID/PID and all other USB function bits, and restarts the module once. The user then selects the original device again to install Engine. Unknown firmware/authentication layouts stop without guessed commands. See [supported profiles, recovery and validation boundaries](../../../docs/MODULE_WEB_INSTALLER.md). Fresh Engine installation still requires the existing administrator-assisted R4 cloud enrollment; an update preserves enrollment.

The same transport can install or update the persistent RM500U or EG25 QDC507 Engine before pairing. `npm run dev` and `npm run build` generate separate `public/engine/<profile>/` artifacts: ARM64 for RM500U and ARMv7 for EG25. Build both native helpers first; prepare the [EG25 runtime](../../../module/eg25/README.md) before building the page. The installer verifies each download and device copy, streams individual files over ADB sync, installs the launcher, audio helper and license files, and writes the init `asm` entry. EG25 also installs DATA11/voice drivers and the ISRG Root X1 supplement. Persistent roots are `/mnt/data/airsim-v2` and `/usrdata/airsim-v2` respectively. Existing identity, cloud configuration, state and pairing remain intact. Inactive Agent releases are pruned before the space check. EG25 capacity failures automatically retry once by stopping the Agent/helper and deleting the old program payloads after all downloads have passed verification. Identity, pairing, configuration and state remain intact. A durable maintenance launcher prevents init from repeatedly starting missing binaries; a disconnected or power-interrupted update can be completed by selecting the module again. The final verified install restores the real launcher, configures init, syncs and clears the maintenance marker. This path deliberately has no local old-binary rollback; RM500U retains its previous behavior. Installation completion requires a responsive Agent with the expected binary, launcher, audio, runtime and license files. USB re-enumeration reconnects only the selected device. Serial-less modules require the system picker again after disconnection because their browser permission is temporary; the page requests installation confirmation rather than reporting an installation failure.

An installed Engine that has not yet created its local sockets is shown as `Engine 正在启动`, with a recheck action. A missing Agent service is not a USB disconnect and does not block first installation or updates. RM500U firmware can spend more than two minutes initializing its kernel random source; the installer waits up to four minutes without dropping a healthy ADB connection. Ready status requires a current manifest, matching runtime files, one executable launcher/init entry and one running Agent whose executable hash and health version match. A configured startup entry still requires a physical reboot test to establish device-level acceptance.

WebRTC Engine artifacts contain a matching Agent and native Opus audio helper plus `OPUS-LICENSE.txt`. Update the v2 App and both ECS control/media services in the same idle window; LC3 components cannot join WebRTC media. The installer reuses hash-matching installed files through hardlinks and removes inactive releases. UBIFS compression is not estimated with a fixed ratio: the installer removes its interrupted staging files before syncing and measuring space, identifies UBIFS by its containing mount point, and adapts writes from 64 KiB down to 4 KiB (or a smaller file tail) while retaining a 512 KiB reserve, and failed staging is removed. Ordinary staging retains the active release; only an EG25 capacity failure enters the low-space replacement path described above. Current links and still-running Agent/helper executables are protected during pruning. Missing storage measurements or an incomplete cleanup stop installation; actual capacity errors include the artifact and measured space. The codec profile and rollback requirements are documented in [WebRTC audio](../../../docs/WEBRTC_AUDIO.md).

`src/pairing.ts` is the page-facing transport interface. The transport owns the polling secret in `sessionStorage`, while the view sees only the operation ID, device identity and eight-digit confirmation code. Wire behavior is frozen in [pairing](../../../protocol/v2/PAIRING.md). See [frontend notes](../../../docs/PAIRING_WEB_FRONTEND.md).

The production build is served by the existing API-domain edge. `AIRSIM_WEB_DIR` points the Compose edge at the built `dist` directory. For a separate development API, set `VITE_AIRSIM_PAIRING_ORIGIN` only at build time; users never enter an address.

## Tests

Vitest exercises the state controller, DOM rendering, asynchronous duplicate actions, operation recovery, Engine readiness/startup/install states, exact firmware/architecture selection, runtime manifest validation, low-space preservation of the active release and local HTTP response framing. It also covers factory USB discovery, separate handles for serial-less modules, AT authorization/configuration checks and real installation scripts in isolated temporary directories. Fixtures live under `tests/` and are not imported by the production entry.

For browser review with the dev server running:

- `/tests/fixture.html?state=list`: keyboard interaction with injected devices.
- `/tests/browser.html?width=1440&state=ready`: an exact-width iframe plus layout measurements.
- Widths: `1440`, `960`, `390`, `320`.
- States: `list`, `empty`, `ready`, `waiting`, `unknown`, `failed`, `connected`, `offline`, `mobile`, `unsupported`.

These are explicit test documents. Vite's production entry is `index.html`; `dist` must not contain `tests/`.

Root LICENSE and NOTICE apply.
