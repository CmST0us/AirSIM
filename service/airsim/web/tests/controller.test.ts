import { describe, expect, it } from 'vitest';
import { PairingController } from '../src/controller';
import { TransportFailure } from '../src/pairing';
import type { ConnectionResult, Device } from '../src/pairing';
import { adapter, deferred, device, environment, operationStore } from './fixtures';

async function setup() {
  const transport = adapter();
  const store = operationStore();
  const controller = new PairingController({ environment, transport, store, operationId: () => 'operation-1' });
  await controller.start();
  return { controller, transport, store };
}

describe('device flow', () => {
  it('starts empty and calls the picker synchronously only after requestDevice', async () => {
    const { controller, transport } = await setup();
    expect(controller.state).toEqual({ kind: 'devices', devices: [] });
    expect(transport.requestDevice).not.toHaveBeenCalled();
    const request = controller.requestDevice();
    expect(transport.requestDevice).toHaveBeenCalledTimes(1);
    await request;
    expect(controller.state).toEqual({ kind: 'ready', device });
    expect(transport.connect).not.toHaveBeenCalled();
  });

  it('guards repeated picker clicks and cancelled selection performs no write', async () => {
    const { controller, transport } = await setup();
    const picker = deferred<Device>();
    transport.requestDevice.mockReturnValue(picker.promise);
    const first = controller.requestDevice();
    await controller.requestDevice();
    expect(transport.requestDevice).toHaveBeenCalledTimes(1);
    picker.reject(new TransportFailure('cancelled'));
    await first;
    expect(controller.state).toEqual({ kind: 'failed', code: 'cancelled' });
    expect(transport.inspect).not.toHaveBeenCalled();
    expect(transport.connect).not.toHaveBeenCalled();
  });

  it.each(['busy', 'disconnected', 'unsupported'] as const)('inspection %s is actionable without connecting', async code => {
    const { controller, transport } = await setup();
    transport.inspect.mockRejectedValue(new TransportFailure(code));
    await controller.requestDevice();
    await controller.connect();
    expect(controller.state).toEqual({ kind: 'failed', code, device });
    expect(transport.connect).not.toHaveBeenCalled();
  });

  it('locks the device and operation while connect is pending', async () => {
    const { controller, transport, store } = await setup();
    await controller.requestDevice();
    const response = deferred<ConnectionResult>();
    transport.connect.mockReturnValue(response.promise);
    const first = controller.connect();
    await controller.connect(); await controller.requestDevice(); await controller.chooseDevice(device.id);
    expect(transport.connect).toHaveBeenCalledTimes(1);
    expect(transport.requestDevice).toHaveBeenCalledTimes(1);
    expect(store.load()?.id).toBe('operation-1');
    expect(controller.state.kind).toBe('connecting');
    response.resolve({ state: 'pending' }); await first;
    expect(controller.state.kind).toBe('pending');
  });

  it('detects an existing phone and writes a reset only after explicit confirmation', async () => {
    const { controller, transport, store } = await setup();
    await controller.requestDevice();
    transport.connect.mockRejectedValueOnce(new TransportFailure('paired'));
    await controller.connect();
    expect(controller.state).toEqual({ kind: 'paired', device });
    expect(store.load()).toBeUndefined();

    const replacement = deferred<ConnectionResult>();
    transport.connect.mockReturnValueOnce(replacement.promise);
    const replacing = controller.replaceExisting();
    expect(transport.connect).toHaveBeenCalledTimes(2);
    expect(transport.connect.mock.calls[1][0]).toMatchObject({ device, replaceExisting: true });
    expect(store.load()).toMatchObject({ device, replaceExisting: true });
    replacement.resolve({ state: 'awaiting_phone', code: '01234567', expiresAt: new Date(Date.now() + 300000).toISOString() });
    await replacing;
  });

  it('installs a missing Engine before exposing the pairing action', async () => {
    const { controller, transport } = await setup();
    const missing = { ...device, engine: { state: 'missing' as const, compatible: true } };
    const installed = { ...device, engine: { state: 'ready' as const, compatible: true, installedVersion: '2.0.0-dev.pairing' } };
    transport.inspect.mockResolvedValue(missing);
    await controller.requestDevice();
    expect(controller.state).toEqual({ kind: 'ready', device: missing });

    const deployment = deferred<Device>();
    transport.install.mockReturnValue(deployment.promise);
    const deploying = controller.installEngine();
    expect(controller.state).toEqual({ kind: 'installing', device: missing, progress: '正在准备 AirSIM Engine…' });
    expect(transport.connect).not.toHaveBeenCalled();
    deployment.resolve(installed);
    await deploying;
    expect(controller.state).toEqual({ kind: 'ready', device: installed });
  });

  it('a disconnect during write becomes unknown and recovery only queries the same operation', async () => {
    const { controller, transport } = await setup();
    await controller.requestDevice();
    transport.connect.mockRejectedValue(new TransportFailure('disconnected'));
    await controller.connect();
    expect(controller.state.kind).toBe('unknown');
    await controller.connect(); await controller.requestDevice();
    const response = deferred<ConnectionResult>();
    transport.status.mockReturnValue(response.promise);
    const query = controller.status(); await controller.status();
    expect(transport.status).toHaveBeenCalledTimes(1);
    expect(transport.status.mock.calls[0][0]).toEqual(transport.connect.mock.calls[0][0]);
    response.resolve({ state: 'connected', online: false }); await query;
    expect(controller.state).toEqual({ kind: 'connected', operation: { id: 'operation-1', device }, online: false });
    expect(transport.connect).toHaveBeenCalledTimes(1);
  });

  it('reload restores an unresolved operation, never replays connect', async () => {
    const { controller, transport, store } = await setup();
    await controller.requestDevice(); await controller.connect();
    controller.dispose();
    const restored = new PairingController({ environment, transport, store });
    await restored.start();
    expect(restored.state.kind).toBe('unknown');
    await restored.status();
    expect(transport.connect).toHaveBeenCalledTimes(1);
    expect(transport.status.mock.calls[0][0].id).toBe('operation-1');
  });

  it('does not write when saving recovery information fails', async () => {
    const transport = adapter();
    const controller = new PairingController({ environment, transport, store: { load: () => undefined, save: () => { throw Error(); }, clear: () => {} } });
    await controller.start(); await controller.requestDevice(); await controller.connect();
    expect(controller.state.kind).toBe('unavailable');
    expect(transport.connect).not.toHaveBeenCalled();
  });

  it('ignores a late picker response after disposal and releases its device', async () => {
    const { controller, transport } = await setup();
    const picker = deferred<Device>(); transport.requestDevice.mockReturnValue(picker.promise);
    const request = controller.requestDevice(); controller.dispose();
    picker.resolve(device); await request;
    expect(transport.inspect).not.toHaveBeenCalled();
    expect(transport.disconnect).toHaveBeenCalledWith(device);
  });

  it('disposal aborts transport work and prevents a late success from updating state', async () => {
    const { controller, transport } = await setup();
    await controller.requestDevice();
    const response = deferred<ConnectionResult>(); transport.connect.mockReturnValue(response.promise);
    const request = controller.connect(); controller.dispose();
    response.resolve({ state: 'connected', online: true }); await request;
    expect(controller.state.kind).toBe('connecting');
    expect(transport.connect.mock.calls[0][1].aborted).toBe(true);
  });

  it.each([
    [{ mobile: true, supported: true }, 'mobile'],
    [{ mobile: false, supported: false }, 'unsupported'],
  ] as const)('unsupported environments never call the adapter', async (environment, kind) => {
    const transport = adapter(); const controller = new PairingController({ environment, transport });
    await controller.start(); await controller.requestDevice();
    expect(controller.state.kind).toBe(kind);
    expect(transport.listGrantedDevices).not.toHaveBeenCalled();
    expect(transport.requestDevice).not.toHaveBeenCalled();
  });

  it('has no production mock fallback', async () => {
    const controller = new PairingController({ environment });
    await controller.start(); expect(controller.state.kind).toBe('unavailable');
  });
});

it('releases a previously inspected device before inspecting a different selection', async () => {
  const { controller, transport } = await setup();
  await controller.requestDevice();
  const second = { ...device, id: 'second-device' };
  transport.requestDevice.mockResolvedValue(second);
  transport.inspect.mockResolvedValue(second);
  await controller.requestDevice();
  expect(transport.disconnect).toHaveBeenCalledWith(device);
  expect(controller.state).toEqual({ kind: 'ready', device: second });
});

it('does not permit a new operation when the recovery record cannot be read', async () => {
  const transport = adapter();
  const controller = new PairingController({ environment, transport,
    store: { load: () => { throw Error(); }, save: () => {}, clear: () => {} },
  });
  await controller.start(); await controller.requestDevice();
  expect(controller.state.kind).toBe('unavailable');
  expect(transport.requestDevice).not.toHaveBeenCalled();
});
