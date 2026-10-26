import { afterEach, expect, it } from 'vitest';
import { PairingController } from '../src/controller';
import { mountPairing } from '../src/view';
import { TransportFailure } from '../src/transport';
import { adapter, deferred, device, environment } from './fixtures';
import type { ConnectionResult } from '../src/transport';

let unmount = () => {};
afterEach(() => { unmount(); document.body.replaceChildren(); });
async function setup() {
  const root = document.createElement('div'); document.body.append(root);
  const transport = adapter();
  const controller = new PairingController({ environment, transport });
  unmount = mountPairing(root, controller); await controller.start();
  return { root, controller, transport };
}

it('shows no fixtures or preview tools before a user selects a device', async () => {
  const { root } = await setup();
  expect(root.textContent).not.toMatch(/RM500|A7K2|JSON|Relay|v1|v2|账户|预览|示例/);
  expect(root.querySelector('h1')?.textContent).toBe('连接设备');
});

it('moves focus to the new heading and connects only on explicit confirmation', async () => {
  const { root, controller, transport } = await setup();
  await controller.requestDevice();
  expect(document.activeElement).toBe(root.querySelector('h1'));
  expect(transport.connect).not.toHaveBeenCalled();
  const response = deferred<ConnectionResult>(); transport.connect.mockReturnValue(response.promise);
  const connect = [...root.querySelectorAll('button')].find(button => button.textContent === '连接设备')!;
  connect.click(); connect.click();
  expect(transport.connect).toHaveBeenCalledTimes(1);
  expect(root.querySelector('h1')?.textContent).toBe('等待设备响应');
  response.resolve({ state: 'connected', online: false });
  await response.promise; await Promise.resolve();
  expect(root.querySelector('h1')?.textContent).toBe('设备未联网');
  expect(root.textContent).not.toContain('设备已连接');
});

it('unknown results offer only original-operation recovery, not retry connect', async () => {
  const { root, controller, transport } = await setup();
  await controller.requestDevice();
  transport.connect.mockRejectedValue(new TransportFailure('unknown'));
  await controller.connect();
  const labels = [...root.querySelectorAll('main button')].map(button => button.textContent);
  expect(labels).toEqual(['查询连接结果']);
});

it('renders adapter text as text rather than markup', async () => {
  const { root, controller, transport } = await setup();
  transport.inspect.mockResolvedValue({ ...device, name: '<img src=x onerror=alert(1)>' });
  await controller.requestDevice();
  expect(root.querySelector('img')).toBeNull();
  expect(root.textContent).toContain('<img src=x onerror=alert(1)>');
});
