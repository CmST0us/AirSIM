// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, symlinkSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { detectPlatform, parseProperties } from '../src/transport/platform';
import { prepareEngineStorageScript, validEngineManifest } from '../src/transport/webusb';

const eg25 = 'os=Linux\nuid=0\narch=armv7l\nkernel=3.18.44\nproject=EG25G_QDC507\nfirmware=QDC507GLEFM21_02.004.03\n';
const file = (path: string) => ({path, size: 64, sha256: 'a'.repeat(64)});
const manifest = {
  schema_version: 1, version: '2.0.0-dev.eg25', os: 'linux', arch: 'arm', profile: 'eg25-qdc507',
  agent: file('airsim-agent'), launcher: file('run-agent.sh'), audio: file('airsim-audiod'),
  platform: ['airsim_data11.ko', 'qdc507_aprv3.ko', 'qdc507_voice.ko', 'COPYING-GPL-2.0', 'MODULE-REPORT.md', 'airsim_data11.c', 'isrgrootx1.pem'].map(file),
  licenses: ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'].map(file),
};
describe('module platform selection', () => {
  it('recognizes the connected QDC507 firmware and rejects other ARMv7 firmware', () => {
    expect(detectPlatform(parseProperties(eg25.replaceAll('\n', '\r\n')))).toBe('eg25-qdc507');
    expect(detectPlatform(parseProperties(eg25.replace('02.004.03', '02.005.01')))).toBeUndefined();
    expect(detectPlatform(parseProperties(eg25.replace('uid=0', 'uid=2000')))).toBeUndefined();
    expect(detectPlatform(parseProperties('os=Linux\nuid=0\narch=aarch64\nhost=udx710-module'))).toBe('rm500u-embedded');
  });
  it('requires a matching CPU artifact and complete platform runtime', () => {
    expect(validEngineManifest(manifest)).toBe(true);
    expect(validEngineManifest({...manifest, arch: 'arm64'})).toBe(false);
    expect(validEngineManifest({...manifest, platform: manifest.platform.slice(1)})).toBe(false);
    expect(validEngineManifest({...manifest, audio: {...manifest.audio, path: '../airsim-audiod'}})).toBe(false);
  });
  it('retains the running release when staging is too large', () => {
    const base = mkdtempSync(join(tmpdir(), 'airsim-storage-'));
    try {
      mkdirSync(join(base, 'releases/current'), {recursive: true});
      mkdirSync(join(base, 'releases/inactive'));
      symlinkSync('releases/current', join(base, 'current'));
      const script = prepareEngineStorageScript('eg25-qdc507', 'new', Number.MAX_SAFE_INTEGER)
        .replace('/usrdata/airsim-v2', base);
      expect(() => execFileSync('sh', ['-c', script], {stdio: 'pipe'})).toThrow();
      expect(existsSync(join(base, 'current'))).toBe(true);
      expect(existsSync(join(base, 'releases/current'))).toBe(true);
      expect(existsSync(join(base, 'releases/inactive'))).toBe(false);
    } finally { rmSync(base, {recursive: true, force: true}); }
  });
});
