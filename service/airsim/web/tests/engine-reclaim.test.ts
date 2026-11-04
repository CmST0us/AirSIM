// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { reclaimEG25EngineScript } from '../src/transport/engine-storage';
import { installEngineScript } from '../src/transport/webusb';

function setup(mode: 'term' | 'kill' | 'stuck' | 'interrupt' = 'term') {
  const root = mkdtempSync(join(tmpdir(), 'airsim-reclaim-'));
  const base = join(root, 'engine');
  for (const dir of ['releases/old', 'audio-releases/old', 'config', 'state', 'platform']) mkdirSync(join(base, dir), { recursive: true });
  symlinkSync('releases/old', join(base, 'current'));
  symlinkSync('audio-releases/old', join(base, 'audio-current'));
  for (const path of ['releases/old/airsim-agent', 'audio-releases/old/airsim-audiod',
    'config/identity.json', 'config/cloud.json', 'state/eg25-sms-seen', 'platform/driver.ko', 'run-agent.sh', 'releases/old/unknown']) {
    writeFileSync(join(base, path), 'original');
  }
  for (const [pid, target] of [[101, 'releases/old/airsim-agent'], [102, 'audio-releases/old/airsim-audiod']] as const) {
    mkdirSync(join(root, 'proc', String(pid)), { recursive: true });
    symlinkSync(join(base, target), join(root, 'proc', String(pid), 'exe'));
  }
  mkdirSync(join(root, 'proc/999'), { recursive: true });
  symlinkSync('/unrelated/airsim-agent', join(root, 'proc/999/exe'));
  writeFileSync(join(root, 'alive'), '');
  const script = reclaimEG25EngineScript().replaceAll('/usrdata/airsim-v2', base)
    .replaceAll('/proc/$pid/exe', `${root}/proc/$pid/exe`);
  const prelude = `
pidof() { if [ -f '${root}/alive' ]; then echo '101 102 999'; else echo 999; fi; }
sync() { :; }
sleep() { :; }
kill() {
  test -f '${base}/.engine-reinstall-pending' || exit 91
  grep -q 'while.*engine-reinstall-pending' '${base}/run-agent.sh' || exit 92
  [ "$2" != 999 ] || exit 93
  echo "$*" >> '${root}/signals'
  ${mode === 'interrupt' ? 'exit 94' : ':'}
  if [ '${mode}' = term ] || { [ '${mode}' = kill ] && [ "$1" = -KILL ]; }; then command rm -f '${root}/alive'; fi
}
rm() {
  test ! -f '${root}/alive' || exit 95
  command rm "$@"
}
`;
  return { root, base, script, prelude, reclaim: () => execFileSync('sh', ['-c', prelude + script], { encoding: 'utf8', stdio: 'pipe' }),
    dispose: () => rmSync(root, { recursive: true, force: true }) };
}

describe('EG25 low-space replacement', () => {
  it.each(['term', 'kill'] as const)('stops owned processes with %s before deleting only program payloads', mode => {
    const f = setup(mode);
    try {
      expect(f.reclaim()).toContain('AIRSIM_ENGINE_RECLAIMED');
      for (const path of ['current/airsim-agent', 'audio-current/airsim-audiod']) expect(existsSync(join(f.base, path))).toBe(false);
      for (const path of ['config/identity.json', 'config/cloud.json', 'state/eg25-sms-seen', 'platform/driver.ko', 'releases/old/unknown']) {
        expect(readFileSync(join(f.base, path), 'utf8')).toBe('original');
      }
      expect(existsSync(join(f.base, '.engine-reinstall-pending'))).toBe(true);
      expect(readFileSync(join(f.root, 'signals'), 'utf8')).not.toContain('999');
      if (mode === 'kill') expect(readFileSync(join(f.root, 'signals'), 'utf8')).toContain('-KILL');
      // Retrying reclamation is safe even when current links are dangling.
      expect(f.reclaim()).toContain('AIRSIM_ENGINE_RECLAIMED');
    } finally { f.dispose(); }
  });

  it.each(['interrupt', 'stuck'] as const)('preserves the recovery marker and payloads if stopping is %s', mode => {
    const f = setup(mode);
    try {
      expect(f.reclaim).toThrow();
      expect(existsSync(join(f.base, '.engine-reinstall-pending'))).toBe(true);
      expect(readFileSync(join(f.base, 'current/airsim-agent'), 'utf8')).toBe('original');
      expect(readFileSync(join(f.base, 'audio-current/airsim-audiod'), 'utf8')).toBe('original');
    } finally { f.dispose(); }
  });

  it('resumes from a durable maintenance launcher only after a verified install restores startup', async () => {
    const f = setup();
    let waiter: ReturnType<typeof spawn> | undefined;
    try {
      f.reclaim();
      // Launch the persisted script as init would after a power interruption.
      waiter = spawn('sh', [join(f.base, 'run-agent.sh')], { stdio: 'ignore' });
      const exited = once(waiter, 'exit');
      mkdirSync(join(f.root, 'etc'));
      writeFileSync(join(f.root, 'etc/inittab'), `asm:12345:respawn:${f.base}/run-agent.sh\n`);
      writeFileSync(join(f.root, 'mounts'), '/dev/root / ubifs ro,relatime 0 0\n');
      mkdirSync(join(f.base, 'releases/new'), { recursive: true });
      const artifact = (name: string, destination: string, contents = `payload ${name}`) => {
        writeFileSync(destination, contents);
        return { path: name, size: contents.length, sha256: createHash('sha256').update(contents).digest('hex') };
      };
      const manifest = { schema_version: 1, version: 'test', os: 'linux', arch: 'arm', profile: 'eg25-qdc507' as const,
        agent: artifact('airsim-agent', join(f.base, 'releases/new/.airsim-agent.new')),
        launcher: artifact('run-agent.sh', join(f.base, '.run-agent.sh.new'), `#!/bin/sh\necho started > '${f.root}/started'\n`),
        audio: artifact('airsim-audiod', join(f.base, '.airsim-audiod.new')),
        licenses: ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'OPUS-LICENSE.txt'].map(name => artifact(name, join(f.base, `.${name}.new`))),
      };
      const install = installEngineScript(manifest, 'new').replaceAll('/usrdata/airsim-v2', f.base)
        .replaceAll('/etc/inittab', join(f.root, 'etc/inittab')).replaceAll('/proc/mounts', join(f.root, 'mounts'));
      const prelude = 'mount() { :; }; kill() { :; }; pidof() { :; }; sync() { :; }; sleep() { :; };\n';
      const audioPath = join(f.base, '.airsim-audiod.new');
      const correctAudio = readFileSync(audioPath);
      writeFileSync(audioPath, 'corrupt');
      expect(() => execFileSync('sh', ['-c', prelude + install], { stdio: 'pipe' })).toThrow();
      expect(existsSync(join(f.base, '.engine-reinstall-pending'))).toBe(true);
      expect(waiter.exitCode).toBeNull();
      expect(existsSync(join(f.root, 'started'))).toBe(false);
      writeFileSync(audioPath, correctAudio);
      expect(execFileSync('sh', ['-c', prelude + install], { encoding: 'utf8' })).toContain('AIRSIM_ENGINE_INSTALLED');
      expect(existsSync(join(f.base, '.engine-reinstall-pending'))).toBe(false);
      expect(await exited).toEqual([0, null]);
      expect(readFileSync(join(f.root, 'started'), 'utf8')).toBe('started\n');
      expect(readFileSync(join(f.base, 'config/identity.json'), 'utf8')).toBe('original');
    } finally { waiter?.kill(); f.dispose(); }
  });
});
