/** Page-level contract. No credentials or wire-protocol fields enter the view. */
export interface Device {
  id: string;
  name: string;
  shortId: string;
}

export interface Operation {
  id: string;
  device: Device;
  replaceExisting?: boolean;
}

export type ConnectionResult =
  | { state: 'pending' }
  | { state: 'awaiting_phone'; code: string; expiresAt: string }
  | { state: 'expired' | 'cancelled' }
  | { state: 'connected'; online: boolean }
  | { state: 'failed' };

export type FailureCode = 'cancelled' | 'busy' | 'disconnected' | 'unsupported' | 'not_ready' | 'paired' | 'failed' | 'unknown';

export class TransportFailure extends Error {
  constructor(readonly code: FailureCode) { super(code); }
}

/** requestDevice must invoke the system picker before its first await. */
export interface DeviceTransport {
  listGrantedDevices(signal: AbortSignal): Promise<readonly Device[]>;
  requestDevice(signal: AbortSignal): Promise<Device>;
  inspect(device: Device, signal: AbortSignal): Promise<Device>;
  /** Repeated delivery of the same Operation must not start another write. */
  connect(operation: Operation, signal: AbortSignal): Promise<ConnectionResult>;
  status(operation: Operation, signal: AbortSignal): Promise<ConnectionResult>;
  /** Cancel an unclaimed session; an already claimed session returns connected. */
  cancel(operation: Operation, signal: AbortSignal): Promise<ConnectionResult>;
  /** Release local handles only; never unpair or reset a device. */
  disconnect(device: Device): Promise<void>;
}
