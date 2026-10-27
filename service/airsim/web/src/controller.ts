import type { OperationStore } from './operation-store';
import type { Environment } from './environment';
import { TransportFailure } from './pairing';
import type { ConnectionResult, Device, DeviceTransport, FailureCode, Operation } from './pairing';

export type State =
  | { kind: 'mobile' | 'unsupported' | 'unavailable' | 'loading' }
  | { kind: 'devices' | 'selecting'; devices: readonly Device[] }
  | { kind: 'inspecting' | 'ready'; device: Device }
  | { kind: 'paired'; device: Device }
  | { kind: 'connecting' | 'pending' | 'checking' | 'unknown' | 'cancelling' | 'expired' | 'cancelled'; operation: Operation }
  | { kind: 'awaiting_phone'; operation: Operation; code: string; expiresAt: string }
  | { kind: 'connected'; operation: Operation; online: boolean }
  | { kind: 'failed'; code: FailureCode; device?: Device };

export interface ControllerOptions {
  environment: Environment;
  transport?: DeviceTransport;
  operationId?: () => string;
  store?: OperationStore;
}

export class PairingController {
  state: State = { kind: 'loading' };
  private listeners = new Set<(state: State) => void>();
  private lifetime = new AbortController();
  private generation = 0;
  private disposed = false;
  private pollTimer?: ReturnType<typeof setTimeout>;
  private statusInFlight = false;
  private heldDevice?: Device;
  private readonly operationId: () => string;

  constructor(private readonly options: ControllerOptions) {
    this.operationId = options.operationId ?? (() => crypto.randomUUID());
  }

  subscribe(listener: (state: State) => void): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }

  private set(state: State) {
    if (this.disposed) return;
    clearTimeout(this.pollTimer);
    this.state = state;
    if (state.kind === 'awaiting_phone' || state.kind === 'pending') {
      this.pollTimer = setTimeout(() => { void this.status(true); }, 2000);
    }
    for (const listener of this.listeners) listener(state);
  }

  private current(generation: number) { return !this.disposed && generation === this.generation; }
  private code(error: unknown): FailureCode {
    return error instanceof TransportFailure ? error.code : 'unknown';
  }

  async start() {
    if (this.disposed || this.state.kind !== 'loading') return;
    if (this.options.environment.mobile) { this.set({ kind: 'mobile' }); return; }
    if (!this.options.environment.supported) { this.set({ kind: 'unsupported' }); return; }
    const transport = this.options.transport;
    if (!transport) { this.set({ kind: 'unavailable' }); return; }
    const generation = ++this.generation;
    try {
      const pending = this.options.store?.load();
      if (pending) { this.set({ kind: 'unknown', operation: pending }); return; }
    } catch { this.set({ kind: 'unavailable' }); return; }
    try {
      const devices = await transport.listGrantedDevices(this.lifetime.signal);
      if (this.current(generation)) this.set({ kind: 'devices', devices });
    } catch (error) {
      if (this.current(generation)) this.set({ kind: 'failed', code: this.code(error) });
    }
  }

  /** Runs synchronously through the adapter picker call to preserve user activation. */
  async requestDevice() {
    if (this.disposed || !['devices', 'failed', 'paired', 'ready'].includes(this.state.kind)) return;
    const transport = this.options.transport;
    if (!transport) return;
    const generation = ++this.generation;
    const devices = this.state.kind === 'devices' ? this.state.devices : [];
    this.set({ kind: 'selecting', devices });
    try {
      const device = await transport.requestDevice(this.lifetime.signal);
      if (!this.current(generation)) { await transport.disconnect(device); return; }
      await this.inspect(device, generation);
    } catch (error) {
      if (this.current(generation)) this.set({ kind: 'failed', code: this.code(error) });
    }
  }

  async chooseDevice(id: string) {
    if (this.disposed || this.state.kind !== 'devices') return;
    const device = this.state.devices.find(item => item.id === id);
    if (device) await this.inspect(device, ++this.generation);
  }

  private async inspect(device: Device, generation: number) {
    const transport = this.options.transport!;
    const previous = this.heldDevice;
    this.set({ kind: 'inspecting', device });
    try {
      if (previous && previous.id !== device.id) await transport.disconnect(previous);
      if (!this.current(generation)) return;
      this.heldDevice = device;
      const inspected = await transport.inspect(device, this.lifetime.signal);
      if (this.current(generation)) {
        this.heldDevice = inspected;
        this.set({ kind: 'ready', device: inspected });
      }
    } catch (error) {
      if (this.current(generation)) this.set({ kind: 'failed', code: this.code(error), device });
    }
  }

  async connect() {
    if (this.disposed || this.state.kind !== 'ready') return;
    const operation = { id: this.operationId(), device: this.state.device };
    try { this.options.store?.save(operation); }
    catch { this.set({ kind: 'unavailable' }); return; }
    const generation = ++this.generation;
    this.set({ kind: 'connecting', operation });
    try {
      const result = await this.options.transport!.connect(operation, this.lifetime.signal);
      if (this.current(generation)) this.result(operation, result);
    } catch (error) {
      // The write may have reached the device. Only status can resolve it.
      if (!this.current(generation)) return;
      if (this.code(error) === 'paired') {
        try { this.options.store?.clear(); } catch { /* Recovery is not needed before a device write. */ }
        this.set({ kind: 'paired', device: operation.device });
      } else {
        this.set({ kind: 'unknown', operation });
      }
    }
  }

  async replaceExisting() {
    if (this.disposed || this.state.kind !== 'paired') return;
    const operation: Operation = {
      id: this.operationId(), device: this.state.device, replaceExisting: true,
    };
    try { this.options.store?.save(operation); }
    catch { this.set({ kind: 'unavailable' }); return; }
    const generation = ++this.generation;
    this.set({ kind: 'connecting', operation });
    try {
      const result = await this.options.transport!.connect(operation, this.lifetime.signal);
      if (this.current(generation)) this.result(operation, result);
    } catch (error) {
      if (!this.current(generation)) return;
      if (this.code(error) === 'paired') {
        try { this.options.store?.clear(); } catch { /* Recovery is not needed before a device write. */ }
        this.set({ kind: 'paired', device: operation.device });
      } else {
        this.set({ kind: 'unknown', operation });
      }
    }
  }

  async status(background = false) {
    if (this.disposed || this.statusInFlight || !['unknown', 'pending', 'connected', 'awaiting_phone'].includes(this.state.kind)
      || !('operation' in this.state)) return;
    const operation = this.state.operation;
    const generation = ++this.generation;
    this.statusInFlight = true;
    if (!background) this.set({ kind: 'checking', operation });
    try {
      const result = await this.options.transport!.status(operation, this.lifetime.signal);
      if (this.current(generation)) this.result(operation, result);
    } catch {
      if (this.current(generation)) this.set({ kind: 'unknown', operation });
    } finally {
      if (this.current(generation)) this.statusInFlight = false;
    }
  }

  async cancel() {
    if (this.disposed || !['awaiting_phone', 'pending', 'unknown'].includes(this.state.kind)
      || !('operation' in this.state)) return;
    const operation = this.state.operation;
    const generation = ++this.generation;
    this.statusInFlight = false;
    this.set({ kind: 'cancelling', operation });
    try {
      const result = await this.options.transport!.cancel(operation, this.lifetime.signal);
      if (this.current(generation)) this.result(operation, result);
    } catch {
      if (this.current(generation)) this.set({ kind: 'unknown', operation });
    }
  }

  async retry() {
    if (this.disposed || !['expired', 'cancelled'].includes(this.state.kind)
      || !('operation' in this.state)) return;
    await this.inspect(this.state.operation.device, ++this.generation);
  }

  private result(operation: Operation, result: ConnectionResult) {
    if (['connected', 'expired', 'cancelled', 'failed'].includes(result.state)) {
      try { this.options.store?.clear(); } catch { /* A later reload can query the completed operation. */ }
    }
    if (result.state === 'connected') this.set({ kind: 'connected', operation, online: result.online });
    else if (result.state === 'awaiting_phone') {
      if (!/^\d{8}$/.test(result.code) || !Number.isFinite(Date.parse(result.expiresAt))) {
        this.set({ kind: 'unknown', operation }); return;
      }
      this.set({ kind: 'awaiting_phone', operation, code: result.code, expiresAt: result.expiresAt });
    }
    else if (result.state === 'expired' || result.state === 'cancelled') this.set({ kind: result.state, operation });
    else if (result.state === 'pending') this.set({ kind: 'pending', operation });
    else this.set({ kind: 'failed', code: 'failed', device: operation.device });
  }

  dispose() {
    this.disposed = true;
    clearTimeout(this.pollTimer);
    this.generation++;
    this.lifetime.abort();
    this.listeners.clear();
    if (this.heldDevice) void this.options.transport?.disconnect(this.heldDevice).catch(() => {});
  }
}
