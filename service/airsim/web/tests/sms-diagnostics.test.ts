import { expect, it } from 'vitest';
import { parseSMSDiagnostics } from '../src/sms-diagnostics';
import { PairingController } from '../src/controller';
import { mountPairing } from '../src/view';
import { adapter, deferred, device, environment } from './fixtures';

const report = {
  schema_version: 1, state: 'ready', observed_at: '2026-11-02T13:00:00Z',
  storage: { error: '', read: { name: 'SM', used: 20, total: 20 }, write: { name: 'ME', used: 0, total: 255 }, receive: { name: 'SM', used: 20, total: 20 } },
  notification: { error: '', values: [2, 1, 0, 0, 0] },
  poll: { observed_at: '2026-11-02T13:00:00Z', error: '', stored_entries: 20, decoded_messages: 19, new_messages: 0, cleanup_error: '' },
};

it('exports only fixed count and configuration fields', () => {
  const safe = parseSMSDiagnostics({ ...report, token: 'private', messages: [{ text: 'private' }],
    storage: { ...report.storage, read: { ...report.storage.read, phone: 'private' } } });
  expect(JSON.stringify(safe)).not.toContain('private');
  expect(safe).toEqual(report);
  expect(() => parseSMSDiagnostics({ ...report, storage: { ...report.storage, read: { name: 'SM', used: 21, total: 20 } } })).toThrow();
  expect(() => parseSMSDiagnostics({ ...report, poll: { ...report.poll, error: 'raw-sensitive-value' } })).toThrow();
});

it('runs diagnostics once without pairing, installing or resetting a module', async () => {
  const transport = adapter();
  transport.inspect.mockResolvedValue({ ...device, engine: { state: 'ready', profile: 'eg25-qdc507', compatible: true } });
  const c = new PairingController({ environment, transport });
  const root = document.createElement('div'); document.body.append(root);
  const cleanup = mountPairing(root, c);
  try {
    await c.start(); await c.requestDevice();
    const pending = deferred<ReturnType<typeof parseSMSDiagnostics>>();
    transport.diagnoseSMS.mockReturnValue(pending.promise);
    const first = c.diagnoseSMS(); await c.diagnoseSMS(); await c.connect(); await c.installEngine();
    expect(transport.diagnoseSMS).toHaveBeenCalledTimes(1);
    pending.resolve(parseSMSDiagnostics(report)); await first;
    expect(root.textContent).toContain('已满');
    expect(root.querySelector('textarea')?.value).toBe(JSON.stringify(report, null, 2));
    expect(transport.connect).not.toHaveBeenCalled(); expect(transport.install).not.toHaveBeenCalled();
    await c.refreshDevice(); expect(c.state.kind).toBe('ready');
  } finally { cleanup(); root.remove(); }
});
