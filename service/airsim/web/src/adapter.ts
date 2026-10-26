import type { DeviceTransport } from './transport';

/** Replace this factory when the device transport contract is frozen. */
export function createDeviceTransport(): DeviceTransport | undefined {
  return undefined;
}
