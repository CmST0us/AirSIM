// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkEngineStorage, engineWriteSize, prepareEngineStorageScript } from '../src/transport/engine-storage';

function fixture(run: (f: { base: string; execute: (mounts: string, free: string, required?: number) => string }) => void) {
  const root = mkdtempSync(join(tmpdir(), 'airsim-space-test-'));
  const base = join(root, 'engine');
  try {
    for (const directory of ['releases/current', 'releases/old', 'releases/running',
      'audio-releases/current', 'audio-releases/old', 'audio-releases/running', 'config', 'state']) {
      mkdirSync(join(base, directory), { recursive: true });
    }
    symlinkSync('releases/current', join(base, 'current'));
    symlinkSync('audio-releases/current', join(base, 'audio-current'));
    for (const path of ['releases/current/airsim-agent', 'audio-releases/current/airsim-audiod',
      'releases/running/airsim-agent', 'audio-releases/running/airsim-audiod',
      'config/identity.json', 'state/eg25-sms-seen', '.unrelated.new']) {
      writeFileSync(join(base, path), 'keep');
    }
    for (const path of ['.airsim-audiod.new', '.run-agent.sh.new', '.airsim-install.sh.new',
      '.airsim_data11.ko.new', 'releases/current/.airsim-agent.new']) {
      writeFileSync(join(base, path), 'interrupted transfer');
    }
    for (const [pid, target] of [[101, 'releases/running/airsim-agent'], [102, 'audio-releases/running/airsim-audiod']] as const) {
      mkdirSync(join(root, 'proc', String(pid)), { recursive: true });
      symlinkSync(join(base, target), join(root, 'proc', String(pid), 'exe'));
    }
    run({ base, execute: (mounts, free, required = 12 * 1024 * 1024) => {
      writeFileSync(join(root, 'mounts'), mounts);
      const script = prepareEngineStorageScript('eg25-qdc507', 'new', required)
        .replaceAll('/usrdata/airsim-v2', base)
        .replaceAll('/proc/mounts', join(root, 'mounts'))
        .replaceAll('/proc/$pid/exe', `${root}/proc/$pid/exe`);
      const prelude = `
pidof() { echo '101 102'; }
sync() {
  # An interrupted transfer must be gone before we commit and measure.
  test ! -e '${base}/.airsim-audiod.new' || exit 91
  test ! -e '${base}/releases/current/.airsim-agent.new' || exit 92
  touch '${root}/synced'
}
df() {
  test -f '${root}/synced' || exit 93
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n'
  printf '/dev/ubi0_4 15000 14000 ${free} 95%% ${root}\\n'
}
`;
      return execFileSync('sh', ['-c', prelude + script], { encoding: 'utf8', stdio: 'pipe' });
    } });
  } finally { rmSync(root, { recursive: true, force: true }); }
}

describe('Engine staging storage', () => {
  it('cleans interrupted files before sync/df, accepts UBIFS device aliases and protects live files', () => fixture(({ base, execute }) => {
    const output = execute(`rootfs / rootfs rw 0 0\nubi0:usrdata ${base} ubifs rw 0 0\n`, '600');
    expect(() => checkEngineStorage(output)).not.toThrow();
    for (const path of ['releases/current/airsim-agent', 'releases/running/airsim-agent',
      'audio-releases/current/airsim-audiod', 'audio-releases/running/airsim-audiod',
      'config/identity.json', 'state/eg25-sms-seen', '.unrelated.new']) {
      expect(readFileSync(join(base, path), 'utf8')).toBe('keep');
    }
    for (const path of ['releases/old', 'audio-releases/old', '.airsim-install.sh.new',
      '.airsim_data11.ko.new', '.run-agent.sh.new']) expect(existsSync(join(base, path))).toBe(false);
  }));

  it('uses the longest containing mount, not a UBIFS parent or sibling', () => fixture(({ base, execute }) => {
    expect(() => execute(`ubi0:root / ubifs rw 0 0\nubi0:data ${base}-other ubifs rw 0 0\n/dev/data ${base} ext4 rw 0 0\n`, '600')).toThrow();
    expect(existsSync(join(base, 'current/airsim-agent'))).toBe(true);
  }));

  it.each(['', 'unknown', '-1', '0', '511', '515'])('stops with free space %j without removing the current release', free => fixture(({ base, execute }) => {
    expect(() => execute(`ubi0:data ${base} ubifs rw 0 0\n`, free)).toThrow();
    expect(readFileSync(join(base, 'current/airsim-agent'), 'utf8')).toBe('keep');
  }));

  it('does not swallow a failed cleanup or df command as success', () => {
    expect(() => checkEngineStorage('permission denied')).toThrow();
    expect(() => checkEngineStorage('AIRSIM_ENGINE_STORAGE_UNKNOWN')).toThrow();
    let failure: unknown;
    try { checkEngineStorage('AIRSIM_ENGINE_STORAGE_SHORT:500:516\r\n'); } catch (error) { failure = error; }
    expect(failure).toMatchObject({ code: 'install_failed', detail: expect.stringMatching(/500 KiB.*516 KiB/) });
  });

  it('continues a compressible tail in smaller writes without crossing the reserve', () => {
    let remaining = 64 * 1024;
    let free = 552;
    const writes: number[] = [];
    while (remaining) {
      const count = engineWriteSize(String(free), remaining);
      expect(free * 1024 - count).toBeGreaterThanOrEqual(512 * 1024);
      writes.push(count);
      remaining -= count;
      // Model 50% compression, while each individual write budgets raw bytes.
      free -= count / 2 / 1024;
    }
    expect(writes).toEqual([40 * 1024, 20 * 1024, 4 * 1024]);
    expect(free).toBe(520);
  });

  it('stops an incompressible tail, accepts exact small tails and fails closed on malformed df', () => {
    expect(engineWriteSize('576', 128 * 1024)).toBe(64 * 1024);
    expect(engineWriteSize('513', 1024)).toBe(1024);
    expect(engineWriteSize('512', 0)).toBe(0);
    expect(() => engineWriteSize('512', 1)).toThrow();
    expect(() => engineWriteSize('515', 65536)).toThrow();
    for (const text of ['', ' ', '-1', 'NaN', '600 extra', '1e3', 'Infinity']) {
      expect(() => engineWriteSize(text, 1024)).toThrow();
    }
  });
});
