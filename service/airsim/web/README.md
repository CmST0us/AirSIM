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

The same transport can install or update the persistent RM500U Engine before pairing. `npm run dev` and `npm run build` generate `public/engine/` from `module/airsim-agent` and `module/rm500/audio`: the Linux/arm64 Agent, launcher, native audio helper and a hashed manifest. The page verifies every download, transfers one tar bundle over WebUSB/ADB, verifies the device copy, installs into `/mnt/data/airsim-v2`, writes the BusyBox `asm` startup entry, and restarts the Agent. Existing module identity, cloud configuration, state, current pairing and `audio-current` remain intact. Superseded release directories are pruned only after storage inspection; the active release is retained through the switch.

An installed Engine that has not yet created its local sockets is shown as `Engine 正在启动`, with a recheck action. RM500U firmware can spend more than two minutes initializing its kernel random source, so absence of the socket during that window is not treated as a missing installation.

`src/pairing.ts` is the page-facing transport interface. The transport owns the polling secret in `sessionStorage`, while the view sees only the operation ID, device identity and eight-digit confirmation code. Wire behavior is frozen in [pairing](../../../protocol/v2/PAIRING.md). See [frontend notes](../../../docs/PAIRING_WEB_FRONTEND.md).

The production build is served by the existing API-domain edge. `AIRSIM_WEB_DIR` points the Compose edge at the built `dist` directory. For a separate development API, set `VITE_AIRSIM_PAIRING_ORIGIN` only at build time; users never enter an address.

## Tests

Vitest exercises the state controller, DOM rendering, asynchronous duplicate actions, operation recovery, Engine readiness/startup/install states, tar-bundle construction and local HTTP response framing. Fixtures live under `tests/` and are not imported by the production entry.

For browser review with the dev server running:

- `/tests/fixture.html?state=list`: keyboard interaction with injected devices.
- `/tests/browser.html?width=1440&state=ready`: an exact-width iframe plus layout measurements.
- Widths: `1440`, `960`, `390`, `320`.
- States: `list`, `empty`, `ready`, `waiting`, `unknown`, `failed`, `connected`, `offline`, `mobile`, `unsupported`.

These are explicit test documents. Vite's production entry is `index.html`; `dist` must not contain `tests/`.

Root LICENSE and NOTICE apply.
