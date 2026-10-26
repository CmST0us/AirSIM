import { vi } from 'vitest';
import type { Device, DeviceTransport, Operation } from '../src/transport';
import type { OperationStore } from '../src/operation-store';

export const device: Device = { id: 'test-device', name: 'RM500', shortId: 'A7K2' };
export const environment = { mobile: false, supported: true };
export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
export function adapter() {
  return {
    listGrantedDevices: vi.fn<DeviceTransport['listGrantedDevices']>().mockResolvedValue([]),
    requestDevice: vi.fn<DeviceTransport['requestDevice']>().mockResolvedValue(device),
    inspect: vi.fn<DeviceTransport['inspect']>().mockResolvedValue(device),
    connect: vi.fn<DeviceTransport['connect']>().mockResolvedValue({ state: 'pending' }),
    status: vi.fn<DeviceTransport['status']>().mockResolvedValue({ state: 'pending' }),
    disconnect: vi.fn<DeviceTransport['disconnect']>().mockResolvedValue(undefined),
  };
}
export function operationStore(): OperationStore {
  let operation: Operation | undefined;
  return { load: () => operation, save: value => { operation = value; }, clear: () => { operation = undefined; } };
}
