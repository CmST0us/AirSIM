// @vitest-environment node
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createHash } from 'node:crypto';
import { AdbDaemonTransport, type AdbTransport } from '@yume-chan/adb';
import { createWebUsbTransport } from '../src/transport/webusb';
import { usbDevice } from './usb-fixtures';
const base = '/usrdata/airsim-v2';
const encoder = new TextEncoder();
const sha = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
const hardware = 'os=Linux\nuid=0\narch=armv7l\nkernel=3.18.44\nproject=EG25G_QDC507\nfirmware=QDC507GLEFM21_02.004.03';
function socket(text: string) {
  return { readable: new ReadableStream({ start(c) { c.enqueue(encoder.encode(text)); c.close(); } }),
    writable: new WritableStream(), close: async () => {}, closed: Promise.resolve(), service: '' };
}
type Failure = 'capacity' | 'device-full' | 'preflight' | 'download' | 'unknown-space' | 'usb-write' | 'second-write' | 'corrupt-copy';
function setup(failure: Failure) {
  const payloads = new Map<string, Uint8Array>();
  const artifact = (name: string) => {
    const bytes = encoder.encode(`new verified ${name}`); payloads.set(name, bytes);
    return { path: name, size: bytes.length, sha256: sha(bytes) };
  };
  const manifest = { schema_version: 1, version: 'test', os: 'linux', arch: 'arm', profile: 'eg25-qdc507',
    agent: artifact('airsim-agent'), launcher: artifact('run-agent.sh'), audio: artifact('airsim-audiod'),
    platform: ['airsim_data11.ko', 'qdc507_aprv3.ko', 'qdc507_voice.ko', 'COPYING-GPL-2.0', 'MODULE-REPORT.md', 'airsim_data11.c', 'isrgrootx1.pem'].map(artifact),
    licenses: ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'OPUS-LICENSE.txt'].map(artifact) };
  const paths = [`${base}/current/airsim-agent`, `${base}/run-agent.sh`, `${base}/audio-current/airsim-audiod`,
    ...manifest.platform.map(f => `${base}/platform/${f.path}`), ...manifest.licenses.map(f => `${base}/licenses/${f.path}`)];
  const artifacts = [manifest.agent, manifest.launcher, manifest.audio, ...manifest.platform, ...manifest.licenses];
  const files = new Map(paths.map((p, i) => [p, i === 0 || i === 2 ? encoder.encode('old') : payloads.get(artifacts[i].path)!]));
  const events: string[] = [];
  let reclaimed = false;
  let activated = false;
  const staged = `${base}/releases/${manifest.agent.sha256.slice(0, 16)}/.airsim-agent.new`;
  const { raw } = usbDevice(true);
  const usb = { raw, serial: 'selected', name: 'Baiwang', connect: async () => ({} as never) };
  const connect = vi.fn(async (service: string) => {
    if (service.startsWith('localfilesystem:')) return socket('HTTP/1.0 200 OK\r\n\r\n' + JSON.stringify({ status: 'ok', version: 'test', agent_boot_id: 'boot' }));
    if (service.startsWith('exec:')) { activated = true; events.push('activate'); return socket('AIRSIM_ENGINE_INSTALLED'); }
    if (service === 'sync:') {
      let reader!: ReadableStreamDefaultController<Uint8Array>;
      let kind = ''; let path = ''; let body = new Uint8Array();
      return { readable: new ReadableStream<Uint8Array>({ start(c) { reader = c; } }),
        writable: new WritableStream<Uint8Array>({ write(bytes) {
          if (kind === 'SEND') { path = new TextDecoder().decode(bytes).split(',')[0]; kind = ''; return; }
          if (kind === 'DATA') {
            if (failure === 'usb-write' || (failure === 'second-write' && reclaimed)) throw new Error('USB transfer failed');
            const next = new Uint8Array(body.length + bytes.length); next.set(body); next.set(bytes, body.length); body = next; kind = ''; return;
          }
          kind = new TextDecoder().decode(bytes.subarray(0, 4));
          if (kind === 'DONE') {
            if (failure === 'device-full' && !reclaimed) {
              const message = encoder.encode('write failed: No space left on device');
              const response = new Uint8Array(8 + message.length);
              response.set(encoder.encode('FAIL')); new DataView(response.buffer).setUint32(4, message.length, true);
              response.set(message, 8); reader.enqueue(response); reader.close(); kind = ''; return;
            }
            files.set(path, failure === 'corrupt-copy' ? encoder.encode('corrupt') : body);
            events.push(`write:${path}`); reader.enqueue(encoder.encode('OKAY\0\0\0\0')); reader.close(); kind = '';
          }
        } }), close: async () => {}, closed: Promise.resolve(), service };
    }
    if (!service.startsWith('shell:')) throw new Error('Unexpected ADB service');
    if (service.includes("printf 'os=")) return socket(hardware);
    if (service.includes('echo pending || echo normal')) return socket(reclaimed ? 'pending' : 'normal');
    if (service.includes('AIRSIM_ENGINE_STAGING_CLEAN')) {
      for (const p of files.keys()) if (p.endsWith('.new')) files.delete(p);
      events.push('cleanup'); return socket('AIRSIM_ENGINE_STAGING_CLEAN');
    }
    if (service.includes('owned_pids()')) {
      expect(events.filter(e => e.startsWith('download:'))).toHaveLength(artifacts.length);
      expect(files.has(staged)).toBe(false);
      reclaimed = true; files.delete(paths[0]); files.delete(paths[2]); files.set(paths[1], encoder.encode('maintenance'));
      events.push('reclaim'); return socket('AIRSIM_ENGINE_RECLAIMED');
    }
    if (service.includes('AIRSIM_ENGINE_STORAGE_READY')) {
      events.push('preflight');
      return socket(failure === 'preflight' && !reclaimed ? 'AIRSIM_ENGINE_STORAGE_SHORT:500:516' : 'AIRSIM_ENGINE_STORAGE_READY');
    }
    if (service.includes("printf '0=%s")) return socket(paths.map((p, i) => `${i}=${files.has(p) ? sha(files.get(p)!) : ''}`).join('\n'));
    if (service.startsWith('shell:sync; df')) return socket(failure === 'unknown-space' ? '' :
      !reclaimed && ['capacity', 'second-write'].includes(failure) ? '512' : '4096');
    if (service.startsWith('shell:ln ')) {
      const [, source, destination] = service.slice(6).split(' ');
      if (!files.has(source)) throw new Error('Attempted to reuse deleted source');
      files.set(destination, files.get(source)!); events.push(`link:${source}`); return socket('');
    }
    if (service.startsWith('shell:sha256sum ')) {
      const p = service.slice('shell:sha256sum '.length).split(' ')[0]; return socket(files.has(p) ? sha(files.get(p)!) : '');
    }
    if (service.includes("printf 'agent=%s")) {
      expect(activated).toBe(true);
      return socket(['agent=1', 'autostart=1', 'asm_entries=1', 'launcher=1', 'running_count=1', 'reinstall_pending=0',
        `hash=${manifest.agent.sha256}`, `running_hash=${manifest.agent.sha256}`, `launcher_hash=${manifest.launcher.sha256}`, `audio_hash=${manifest.audio.sha256}`,
        ...[...manifest.platform, ...manifest.licenses].map(f => `${f.path}=${f.sha256}`)].join('\n'));
    }
    if (service.includes('mkdir -p')) return socket('');
    throw new Error('Unexpected shell command in installer test');
  });
  const backend = { connect, close: async () => {}, disconnected: new Promise<void>(() => {}), clientFeatures: [], banner: { features: [] }, serial: 'selected', maxPayloadSize: 4096 } as unknown as AdbTransport;
  vi.spyOn(AdbDaemonTransport, 'authenticate').mockResolvedValue(backend as AdbDaemonTransport);
  const transport = createWebUsbTransport({ manager: { requestDevice: async () => usb, getDevices: async () => [usb] },
    serviceOrigin: 'https://airsim.example', storage: {} as Storage,
    fetch: async input => {
      const name = String(input).split('/').pop()!;
      if (name === 'manifest.json') return new Response(JSON.stringify(manifest));
      events.push(`download:${name}`);
      return new Response(failure === 'download' && name === 'airsim-audiod' ? 'bad download' : payloads.get(name)!.slice().buffer);
    } })!;
  return { install: () => transport.install({ id: 'selected', name: 'Baiwang', shortId: '' }, new AbortController().signal, () => {}), events };
}
afterEach(() => vi.restoreAllMocks());
describe('WebUSB installer capacity fallback', () => {
  it.each(['capacity', 'device-full', 'preflight'] as const)('recovers from %s failure, rechecks reusable files and installs', async failure => {
    const f = setup(failure);
    expect((await f.install()).engine?.state).toBe('ready');
    expect(f.events.filter(e => e === 'reclaim')).toHaveLength(1);
    expect(f.events).toContain('activate');
    expect(f.events).toContain(`write:${base}/.run-agent.sh.new`);
    expect(f.events).toContain(`write:${base}/.airsim-audiod.new`);
  });
  it.each(['download', 'unknown-space', 'usb-write', 'corrupt-copy'] as const)('never deletes the old version on %s failure', async failure => {
    const f = setup(failure);
    await expect(f.install()).rejects.toBeDefined();
    expect(f.events).not.toContain('reclaim');
    expect(f.events).not.toContain('activate');
  });
  it('reports resumable reinstall instead of claiming the old version survived a second write failure', async () => {
    const f = setup('second-write');
    await expect(f.install()).rejects.toMatchObject({ detail: expect.stringContaining('重新选择模块并继续安装') });
    expect(f.events.filter(e => e === 'reclaim')).toHaveLength(1);
    expect(f.events).not.toContain('activate');
    expect(f.events.at(-1)).toBe('cleanup');
  });
});
