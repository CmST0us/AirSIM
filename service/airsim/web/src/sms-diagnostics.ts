import { TransportFailure } from './pairing';

export interface SMSStorage { name: 'SM' | 'ME' | 'MT'; used: number; total: number }
export interface SMSDiagnostics {
  schema_version: 1;
  state: 'collecting' | 'ready';
  observed_at: string | null;
  storage: { error: string; read: SMSStorage | null; write: SMSStorage | null; receive: SMSStorage | null };
  notification: { error: string; values: number[] | null };
  poll: { observed_at: string | null; error: string; stored_entries: number; decoded_messages: number; new_messages: number; cleanup_error: string };
}

// Construct a new report from an explicit allowlist. Unexpected device fields
// (including any future message or identity fields) never reach the UI/export.
export function parseSMSDiagnostics(value: unknown): SMSDiagnostics {
  const invalid = (): never => { throw new TransportFailure('failed'); };
  const object = (v: unknown): Record<string, unknown> => v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : invalid();
  const count = (v: unknown): number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0 && v <= 1_000_000 ? v : invalid();
  const error = (v: unknown): string => typeof v === 'string' && ['', 'query_failed', 'invalid_response', 'at_desynchronized', 'unavailable'].includes(v) ? v : invalid();
  const date = (v: unknown): string | null => v === null ? null : typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T[\d:.]+Z$/.test(v) && Number.isFinite(Date.parse(v)) ? v : invalid();
  const storage = (v: unknown): SMSStorage | null => {
    if (v === null) return null;
    const s = object(v);
    if (s.name !== 'SM' && s.name !== 'ME' && s.name !== 'MT') return invalid();
    const used = count(s.used), total = count(s.total);
    if (used > total) return invalid();
    return { name: s.name, used, total };
  };
  const r = object(value), s = object(r.storage), n = object(r.notification), p = object(r.poll);
  if (r.schema_version !== 1 || (r.state !== 'collecting' && r.state !== 'ready')) return invalid();
  let values: number[] | null = null;
  if (n.values !== null) {
    if (!Array.isArray(n.values) || n.values.length !== 5) return invalid();
    values = n.values.map(count);
    if (values.some((v, i) => v > [3, 3, 3, 2, 1][i]!)) return invalid();
  }
  return {
    schema_version: 1, state: r.state, observed_at: date(r.observed_at),
    storage: { error: error(s.error), read: storage(s.read), write: storage(s.write), receive: storage(s.receive) },
    notification: { error: error(n.error), values },
    poll: { observed_at: date(p.observed_at), error: error(p.error), stored_entries: count(p.stored_entries), decoded_messages: count(p.decoded_messages), new_messages: count(p.new_messages), cleanup_error: error(p.cleanup_error ?? '') },
  };
}
