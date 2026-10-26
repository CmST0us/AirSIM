import './styles.css';
import { createDeviceTransport } from './adapter';
import { PairingController } from './controller';
import { browserEnvironment } from './environment';
import { sessionOperationStore } from './operation-store';
import { mountPairing } from './view';

const controller = new PairingController({
  environment: browserEnvironment(),
  transport: createDeviceTransport(),
  store: sessionOperationStore(window.sessionStorage),
});
const unmount = mountPairing(document.querySelector<HTMLElement>('#app')!, controller);
void controller.start();
window.addEventListener('pagehide', unmount, { once: true });
window.addEventListener('pageshow', event => { if (event.persisted) window.location.reload(); });
