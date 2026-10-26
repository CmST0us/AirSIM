import type { DeviceTransport } from './pairing';

/** Replace this factory when the device transport contract is frozen. */
export function createDeviceTransport(): DeviceTransport | undefined {
  return undefined;
}
