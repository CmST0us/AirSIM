import type { OperationStore } from './operation-store';
import type { Environment } from './environment';
import { TransportFailure } from './transport';
import type { ConnectionResult, Device, DeviceTransport, FailureCode, Operation } from './transport';

export type State =
  | { kind: 'mobile' | 'unsupported' | 'unavailable' | 'loading' }
  | { kind: 'devices' | 'selecting'; devices: readonly Device[] }
  | { kind: 'inspecting' | 'ready'; device: Device }
  | { kind: 'connecting' | 'pending' | 'checking' | 'unknown'; operation: Operation }
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
    this.state = state;
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
    if (this.disposed || !['devices', 'failed', 'ready'].includes(this.state.kind)) return;
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
    } catch {
      // The write may have reached the device. Only status can resolve it.
      if (this.current(generation)) this.set({ kind: 'unknown', operation });
    }
  }

  async status() {
    if (this.disposed || !['unknown', 'pending', 'connected'].includes(this.state.kind)
      || !('operation' in this.state)) return;
    const operation = this.state.operation;
    const generation = ++this.generation;
    this.set({ kind: 'checking', operation });
    try {
      const result = await this.options.transport!.status(operation, this.lifetime.signal);
      if (this.current(generation)) this.result(operation, result);
    } catch {
      if (this.current(generation)) this.set({ kind: 'unknown', operation });
    }
  }

  private result(operation: Operation, result: ConnectionResult) {
    if (result.state !== 'pending') {
      try { this.options.store?.clear(); } catch { /* A later reload can query the completed operation. */ }
    }
    if (result.state === 'connected') this.set({ kind: 'connected', operation, online: result.online });
    else if (result.state === 'pending') this.set({ kind: 'pending', operation });
    else this.set({ kind: 'failed', code: 'failed', device: operation.device });
  }

  dispose() {
    this.disposed = true;
    this.generation++;
    this.lifetime.abort();
    this.listeners.clear();
    if (this.heldDevice) void this.options.transport?.disconnect(this.heldDevice).catch(() => {});
  }
}
