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

`src/pairing.ts` is the page-facing transport interface. The transport owns the polling secret in `sessionStorage`, while the view sees only the operation ID, device identity and eight-digit confirmation code. Wire behavior is frozen in [R8 pairing](../../../protocol/v2/R8_PAIRING.md). See [frontend notes](../../../docs/PAIRING_WEB_FRONTEND.md).

The production build is served by the existing API-domain edge. `AIRSIM_WEB_DIR` points the Compose edge at the built `dist` directory. For a separate development API, set `VITE_AIRSIM_PAIRING_ORIGIN` only at build time; users never enter an address.

## Tests

Vitest exercises the state controller, DOM rendering, asynchronous duplicate actions, operation recovery and local HTTP response framing. Fixtures live under `tests/` and are not imported by the production entry.

For browser review with the dev server running:

- `/tests/fixture.html?state=list`: keyboard interaction with injected devices.
- `/tests/browser.html?width=1440&state=ready`: an exact-width iframe plus layout measurements.
- Widths: `1440`, `960`, `390`, `320`.
- States: `list`, `empty`, `ready`, `waiting`, `unknown`, `failed`, `connected`, `offline`, `mobile`, `unsupported`.

These are explicit test documents. Vite's production entry is `index.html`; `dist` must not contain `tests/`.

Root LICENSE and NOTICE apply.
