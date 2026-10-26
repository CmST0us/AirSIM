import type { Operation } from './transport';

export interface OperationStore {
  load(): Operation | undefined;
  save(operation: Operation): void;
  clear(): void;
}

const key = 'airsim.pending-device-operation';
export function sessionOperationStore(storage: Storage): OperationStore {
  return {
    load() {
      const raw = storage.getItem(key);
      if (!raw) return;
      const value: unknown = JSON.parse(raw);
      if (typeof value !== 'object' || value === null) throw new Error('Invalid operation');
      const operation = value as Operation;
      if (typeof operation.id !== 'string' || !operation.id
        || !operation.device || ['id', 'name', 'shortId'].some(field =>
          typeof operation.device[field as keyof typeof operation.device] !== 'string')) {
        throw new Error('Invalid operation');
      }
      return operation;
    },
    save(operation) { storage.setItem(key, JSON.stringify(operation)); },
    clear() { storage.removeItem(key); },
  };
}
