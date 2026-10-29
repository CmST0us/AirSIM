/** Page-level contract. No credentials or wire-protocol fields enter the view. */
export interface Device {
  id: string;
  name: string;
  shortId: string;
  engine?: EngineStatus;
}

export interface EngineStatus {
  profile?: string;
  state: 'ready' | 'starting' | 'missing' | 'incomplete' | 'outdated' | 'unavailable';
  installedVersion?: string;
  targetVersion?: string;
  compatible: boolean;
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

export type FailureCode = 'cancelled' | 'busy' | 'disconnected' | 'unsupported' | 'not_ready' | 'paired' | 'install_reconnect' | 'install_failed' | 'failed' | 'unknown';

export class TransportFailure extends Error {
  constructor(readonly code: FailureCode, readonly detail?: string) { super(code); }
}

/** requestDevice must invoke the system picker before its first await. */
export interface DeviceTransport {
  listGrantedDevices(signal: AbortSignal): Promise<readonly Device[]>;
  requestDevice(signal: AbortSignal): Promise<Device>;
  inspect(device: Device, signal: AbortSignal): Promise<Device>;
  /** Installs the served Engine release and enables persistent boot startup. */
  install(device: Device, signal: AbortSignal, progress: (message: string) => void): Promise<Device>;
  /** Repeated delivery of the same Operation must not start another write. */
  connect(operation: Operation, signal: AbortSignal): Promise<ConnectionResult>;
  status(operation: Operation, signal: AbortSignal): Promise<ConnectionResult>;
  /** Cancel an unclaimed session; an already claimed session returns connected. */
  cancel(operation: Operation, signal: AbortSignal): Promise<ConnectionResult>;
  /** Release local handles only; never unpair or reset a device. */
  disconnect(device: Device): Promise<void>;
}
