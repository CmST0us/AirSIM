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

`src/adapter.ts` composes the production WebUSB/ADB transport in `src/transport/webusb.ts`. It uses the system device picker, connects only to the user-selected module, performs the local Ed25519 proof through the protected Agent socket, and then calls the same-origin `/v2/pairing` service. Unsupported browsers and mobile devices show their own instructions. There is no production mock, fixture query parameter, or fallback transport.

The same transport can install or update the persistent RM500U or EG25 QDC507 Engine before pairing. `npm run dev` and `npm run build` generate separate `public/engine/<profile>/` artifacts: ARM64 for RM500U and ARMv7 for EG25. Build both native helpers first; prepare the [EG25 runtime](../../../module/eg25/README.md) before building the page. The installer verifies each download and device copy, streams individual files over ADB sync, installs the launcher, audio helper and license files, and writes the init `asm` entry. EG25 also installs DATA11/voice drivers and the ISRG Root X1 supplement. Persistent roots are `/mnt/data/airsim-v2` and `/usrdata/airsim-v2` respectively. Existing identity, cloud configuration, state and pairing remain intact. Inactive Agent releases are pruned before the space check; the active release is retained through the switch. Installation completion requires a responsive Agent with the expected binary, launcher, audio, runtime and license files. USB re-enumeration reconnects only the selected device. Serial-less modules require the system picker again after disconnection because their browser permission is temporary; the page requests installation confirmation rather than reporting an installation failure.

An installed Engine that has not yet created its local sockets is shown as `Engine 正在启动`, with a recheck action. RM500U firmware can spend more than two minutes initializing its kernel random source, so absence of the socket during that window is not treated as a missing installation.

LC3 Engine artifacts contain a matching Agent and native audio helper plus `LC3-LICENSE.txt`. Update the v2 App and both ECS control/media services in the same idle window; PCM-only media components cannot exchange LC3 frames. The codec profile and rollback requirements are documented in [LC3 audio](../../../docs/LC3_AUDIO.md).

`src/pairing.ts` is the page-facing transport interface. The transport owns the polling secret in `sessionStorage`, while the view sees only the operation ID, device identity and eight-digit confirmation code. Wire behavior is frozen in [pairing](../../../protocol/v2/PAIRING.md). See [frontend notes](../../../docs/PAIRING_WEB_FRONTEND.md).

The production build is served by the existing API-domain edge. `AIRSIM_WEB_DIR` points the Compose edge at the built `dist` directory. For a separate development API, set `VITE_AIRSIM_PAIRING_ORIGIN` only at build time; users never enter an address.

## Tests

Vitest exercises the state controller, DOM rendering, asynchronous duplicate actions, operation recovery, Engine readiness/startup/install states, exact firmware/architecture selection, runtime manifest validation, low-space preservation of the active release and local HTTP response framing. Fixtures live under `tests/` and are not imported by the production entry.

For browser review with the dev server running:

- `/tests/fixture.html?state=list`: keyboard interaction with injected devices.
- `/tests/browser.html?width=1440&state=ready`: an exact-width iframe plus layout measurements.
- Widths: `1440`, `960`, `390`, `320`.
- States: `list`, `empty`, `ready`, `waiting`, `unknown`, `failed`, `connected`, `offline`, `mobile`, `unsupported`.

These are explicit test documents. Vite's production entry is `index.html`; `dist` must not contain `tests/`.

Root LICENSE and NOTICE apply.
