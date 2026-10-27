import { afterEach, expect, it } from 'vitest';
import { PairingController } from '../src/controller';
import { mountPairing } from '../src/view';
import { TransportFailure } from '../src/pairing';
import { adapter, deferred, device, environment } from './fixtures';
import type { ConnectionResult } from '../src/pairing';

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

it('offers persistent Engine installation before pairing a bare module', async () => {
  const { root, controller, transport } = await setup();
  const missing = { ...device, engine: { state: 'missing' as const, compatible: true } };
  const installed = { ...device, engine: { state: 'ready' as const, compatible: true } };
  transport.inspect.mockResolvedValue(missing);
  transport.install.mockResolvedValue(installed);
  await controller.requestDevice();
  expect(root.querySelector('h1')?.textContent).toBe('安装 AirSIM Engine');
  expect(root.textContent).toContain('开机自启');
  const install = [...root.querySelectorAll('button')].find(button => button.textContent === '安装并启用')!;
  const deployment = deferred<typeof installed>();
  transport.install.mockReturnValueOnce(deployment.promise);
  install.click();
  expect(transport.install).toHaveBeenCalledTimes(1);
  expect(transport.connect).not.toHaveBeenCalled();
  deployment.resolve(installed);
  await deployment.promise;
});

it('continues to device confirmation when the persistent Engine is ready', async () => {
  const { root, controller, transport } = await setup();
  transport.inspect.mockResolvedValue({
    ...device,
    engine: { state: 'ready', compatible: true, installedVersion: '2.0.0-dev.pairing' },
  });
  await controller.requestDevice();
  expect(root.querySelector('h1')?.textContent).toBe('确认设备');
  expect(root.textContent).toContain('Engine 2.0.0-dev.pairing · 开机自启');
  expect(root.textContent).toContain('Engine 已启用开机自启');
});

it('shows boot initialization separately and can recheck without reinstalling', async () => {
  const { root, controller, transport } = await setup();
  const ready = {
    ...device,
    engine: { state: 'ready' as const, compatible: true, installedVersion: '2.0.0-dev.pairing' },
  };
  transport.inspect
    .mockResolvedValueOnce({ ...device, engine: { state: 'starting', compatible: true, targetVersion: '2.0.0-dev.pairing' } })
    .mockResolvedValueOnce(ready);
  await controller.requestDevice();
  expect(root.querySelector('h1')?.textContent).toBe('Engine 正在启动');
  expect(root.textContent).toContain('无需重新安装');
  const recheck = [...root.querySelectorAll('button')].find(button => button.textContent === '重新检查')!;
  recheck.click();
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(transport.inspect).toHaveBeenCalledTimes(2);
  expect(root.querySelector('h1')?.textContent).toBe('确认设备');
});

it('explains that a connected device can be reset only with the module in hand', async () => {
  const { root, controller, transport } = await setup();
  await controller.requestDevice();
  transport.connect.mockRejectedValueOnce(new TransportFailure('paired'));
  await controller.connect();
  expect(root.querySelector('h1')?.textContent).toBe('此设备已连接');
  expect(root.textContent).toContain('重置会撤销旧手机');
  expect(root.textContent).toContain('拿到模块并连接电脑的人');

  const replacement = deferred<ConnectionResult>();
  transport.connect.mockReturnValueOnce(replacement.promise);
  const reset = [...root.querySelectorAll('button')].find(button => button.textContent === '重置并继续')!;
  reset.click();
  expect(transport.connect).toHaveBeenCalledTimes(2);
  expect(transport.connect.mock.calls[1][0]).toMatchObject({ replaceExisting: true });
  replacement.resolve({ state: 'pending' });
  await replacement.promise;
});
