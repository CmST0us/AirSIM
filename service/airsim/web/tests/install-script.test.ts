// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, symlinkSync, readlinkSync, rmSync, statSync, linkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { installEngineScript } from '../src/transport/webusb';
import { platforms } from '../src/transport/platform';

describe('persistent installer', () => {
  it.each([
    ['eg25-qdc507', false], ['rm500u-embedded', false],
    ['eg25-qdc507', true], ['rm500u-embedded', true],
  ] as const)('installs %s with reused files=%s and keeps identity', (profile, reuse) => {
    const directory = mkdtempSync(join(tmpdir(), 'airsim-init-test-'));
    const base = join(directory, 'engine');
    const etc = join(directory, 'etc');
    try {
      mkdirSync(join(base, 'releases/new'), { recursive: true });
      mkdirSync(join(base, 'releases/old')); symlinkSync('releases/old', join(base, 'current'));
      mkdirSync(join(base, 'config')); mkdirSync(etc);
      writeFileSync(join(base, 'config/identity.json'), 'synthetic-identity');
      writeFileSync(join(base, 'config/cloud.json'), 'synthetic-cloud');
      const original = `::sysinit:/etc/init.d/rcS\nasm:12345:respawn:/old/run-agent.sh\nasm:12345:respawn:/duplicate/run-agent.sh\n`;
      writeFileSync(join(etc, 'inittab'), original);
      writeFileSync(join(directory, 'mounts'), '/dev/root / ubifs ro,relatime 0 0\n');
      const file = (path: string, destination: string) => {
        const contents = `synthetic ${path}\n`;
        writeFileSync(destination, contents);
        return { path, size: contents.length, sha256: createHash('sha256').update(contents).digest('hex') };
      };
      const manifest = {
        schema_version: 1, version: 'test', os: 'linux', arch: platforms[profile].arch, profile,
        agent: file('airsim-agent', join(base, 'releases/new/.airsim-agent.new')),
        launcher: file('run-agent.sh', join(base, '.run-agent.sh.new')),
        audio: file('airsim-audiod', join(base, '.airsim-audiod.new')),
        licenses: ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'OPUS-LICENSE.txt'].map(name => file(name, join(base, `.${name}.new`))),
      };
      if (reuse) {
        // A hardlinked staged launcher/license must not fail mv as 'same file'.
        linkSync(join(base, '.run-agent.sh.new'), join(base, 'run-agent.sh'));
        mkdirSync(join(base, 'licenses'));
        for (const f of manifest.licenses) linkSync(join(base, `.${f.path}.new`), join(base, 'licenses', f.path));
        linkSync(join(base, 'releases/new/.airsim-agent.new'), join(base, 'releases/new/airsim-agent'));
      }
      const script = installEngineScript(manifest, 'new')
        .replaceAll(platforms[profile].base, base)
        .replaceAll('/etc/inittab', join(etc, 'inittab'))
        .replaceAll('/proc/mounts', join(directory, 'mounts'));
      // Sandbox the real installer: root mounts and PID 1 are recorded, never touched.
      const prelude = `
mount() { echo "mount $*" >> '${directory}/actions'; }
kill() { echo "kill $*" >> '${directory}/actions'; }
pidof() { :; }
sync() { :; }
sleep() { :; }
`;
      const output = execFileSync('sh', ['-c', prelude + script], { encoding: 'utf8' });
      expect(output).toContain('AIRSIM_ENGINE_INSTALLED');
      expect(readFileSync(join(etc, 'inittab'), 'utf8')).toBe(`::sysinit:/etc/init.d/rcS\nasm:12345:respawn:${base}/run-agent.sh\n`);
      expect(readFileSync(join(etc, 'inittab.airsim-backup'), 'utf8')).toBe(original);
      expect(readlinkSync(join(base, 'current'))).toBe('releases/new');
      expect(readFileSync(join(base, 'config/identity.json'), 'utf8')).toBe('synthetic-identity');
      expect(readFileSync(join(base, 'config/cloud.json'), 'utf8')).toBe('synthetic-cloud');
      expect(statSync(join(base, 'run-agent.sh')).mode & 0o777).toBe(0o700);
      expect(readFileSync(join(directory, 'actions'), 'utf8')).toBe('mount -o remount,rw /\nmount -o remount,ro /\nkill -HUP 1\n');
    } finally { rmSync(directory, { recursive: true, force: true }); }
  });
});
