# AirSIM pairing web

TypeScript/Vite page layer for first device connection. The approved local design remains in `design/pairing-web/`; `tests/visual/reference.png` preserves its visual baseline. No design source, backend, iOS, deployment, or device files are modified by this component.

```sh
npm ci
npm test
npm run build
npm run dev -- --port 4174 --strictPort
```

Node 22.12+ is required by the pinned toolchain. Run commands from this directory.

## Integration

`src/adapter.ts` is the production composition point. It currently returns no transport. Supported desktop browsers therefore stop at “设备连接暂不可用”; unsupported browsers and mobile devices show their own instructions. There is no production mock, fixture query parameter, or fallback transport.

`src/transport.ts` describes the provisional page-facing interface, not a frozen wire protocol. Supply one `DeviceTransport` to `PairingController`. The actual WebUSB adapter, permission filters, device protocol and response mapping are provided separately. See [frontend handoff](../../../docs/PAIRING_WEB_FRONTEND.md).

## Tests

Vitest exercises the state controller, DOM rendering, asynchronous duplicate actions and operation recovery. Fixtures live under `tests/` and are not imported by the production entry.

For browser review with the dev server running:

- `/tests/fixture.html?state=list`: keyboard interaction with injected devices.
- `/tests/browser.html?width=1440&state=ready`: an exact-width iframe plus layout measurements.
- Widths: `1440`, `960`, `390`, `320`.
- States: `list`, `empty`, `ready`, `waiting`, `unknown`, `failed`, `connected`, `offline`, `mobile`, `unsupported`.

These are explicit test documents. Vite's production entry is `index.html`; `dist` must not contain `tests/`.

Root LICENSE and NOTICE apply.
