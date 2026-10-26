import '../src/styles.css';
import { PairingController } from '../src/controller';
import { mountPairing } from '../src/view';
import { TransportFailure } from '../src/transport';
import type { DeviceTransport } from '../src/transport';

const scenario = new URLSearchParams(location.search).get('state') ?? 'ready';
const device = { id: 'fixture-only', name: 'RM500', shortId: 'A7K2' };
const transport: DeviceTransport = {
  listGrantedDevices: async () => scenario === 'empty' ? [] : [device],
  requestDevice: async () => device,
  inspect: async () => device,
  connect: async () => {
    if (scenario === 'unknown') throw new TransportFailure('disconnected');
    if (scenario === 'failed') return { state: 'failed' };
    if (scenario === 'waiting') return new Promise(() => {});
    return { state: 'connected', online: scenario !== 'offline' };
  },
  status: async () => ({ state: 'pending' }),
  disconnect: async () => {},
};
const controller = new PairingController({
  transport, environment: { mobile: scenario === 'mobile', supported: scenario !== 'unsupported' },
});
mountPairing(document.querySelector<HTMLElement>('#app')!, controller);
await controller.start();
if (['ready', 'waiting', 'unknown', 'failed', 'connected', 'offline'].includes(scenario)) {
  await controller.chooseDevice(device.id);
  if (scenario !== 'ready') void controller.connect();
}
requestAnimationFrame(() => requestAnimationFrame(() => {
  parent.postMessage({
    width: document.documentElement.clientWidth,
    scrollWidth: document.documentElement.scrollWidth,
    heading: document.querySelector('h1')?.textContent,
    focused: document.activeElement?.tagName,
  }, location.origin);
}));
