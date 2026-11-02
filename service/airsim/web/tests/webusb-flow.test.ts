import { afterEach, describe, expect, it, vi } from 'vitest';
import { AdbDaemonTransport, type AdbTransport } from '@yume-chan/adb';
import { createWebUsbTransport } from '../src/transport/webusb';
import { PairingController } from '../src/controller';
import { mountPairing } from '../src/view';
import { usbDevice } from './usb-fixtures';

const hash = 'a'.repeat(64);
const artifact = (path: string) => ({ path, size: 1, sha256: hash });
const manifest = {
  schema_version: 1, version: '2.0.0-dev.webrtc', os: 'linux', arch: 'arm', profile: 'eg25-qdc507',
  agent: artifact('airsim-agent'), launcher: artifact('run-agent.sh'), audio: artifact('airsim-audiod'),
  platform: ['airsim_data11.ko', 'qdc507_aprv3.ko', 'qdc507_voice.ko', 'COPYING-GPL-2.0', 'MODULE-REPORT.md', 'airsim_data11.c', 'isrgrootx1.pem'].map(artifact),
  licenses: ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'OPUS-LICENSE.txt'].map(artifact),
};
const hardware = 'os=Linux\nuid=0\narch=armv7l\nkernel=3.18.44\nproject=EG25G_QDC507\nfirmware=QDC507GLEFM21_02.004.03';
const installed = ['agent=1', 'autostart=1', 'asm_entries=1', 'launcher=1', 'running_count=1', `hash=${hash}`, `launcher_hash=${hash}`, `audio_hash=${hash}`, `running_hash=${hash}`,
  ...[...manifest.platform, ...manifest.licenses].map(file => `${file.path}=${hash}`)].join('\n');

function socket(text: string) {
  return {
    readable: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(text)); c.close(); } }),
    writable: new WritableStream(), close: vi.fn(async () => {}), closed: Promise.resolve(undefined), service: '',
  };
}

async function setup(properties: string, health = false, releaseAvailable = true) {
  const { raw } = usbDevice(true);
  const usb = { raw, serial: 'selected', name: 'Baiwang', connect: vi.fn(async () => ({} as never)) };
  const connect = vi.fn(async (service: string) => {
    if (service.startsWith('shell:')) return socket(service.includes("printf 'os=") ? hardware : properties);
    if (!health) throw new Error('Socket open failed');
    return socket('HTTP/1.0 200 OK\r\n\r\n' + JSON.stringify({ status: 'ok', version: manifest.version, agent_boot_id: 'boot' }));
  });
  const backend = { connect, close: vi.fn(async () => {}), disconnected: new Promise<void>(() => {}),
    clientFeatures: [], banner: { features: [] }, serial: 'selected', maxPayloadSize: 4096 } as unknown as AdbTransport;
  vi.spyOn(AdbDaemonTransport, 'authenticate').mockResolvedValue(backend as AdbDaemonTransport);
  const transport = createWebUsbTransport({
    manager: { requestDevice: async () => usb, getDevices: async () => [usb] }, storage: sessionStorage,
    fetch: vi.fn(async () => new Response(JSON.stringify(manifest), { status: releaseAvailable ? 200 : 503 })),
  })!;
  const controller = new PairingController({ transport, environment: { mobile: false, supported: true } });
  const root = document.createElement('div'); document.body.append(root);
  const cleanup = mountPairing(root, controller);
  await controller.start(); await controller.requestDevice();
  return { controller, root, connect, cleanup, usb };
}
afterEach(() => { vi.restoreAllMocks(); document.body.replaceChildren(); });

describe('real inspection flow with ADB service rejection', () => {
  it.each([
    ['agent=0\nautostart=0', '安装 AirSIM Engine', '安装并启用'],
    [installed, 'Engine 正在启动', '重新检查'],
    [installed.replace('autostart=1', 'autostart=0'), '安装 AirSIM Engine', '更新并启用'],
    [installed.replace(`hash=${hash}`, `hash=${'b'.repeat(64)}`), '安装 AirSIM Engine', '更新并启用'],
  ])('keeps USB connected when Agent is unavailable: %s', async (properties, heading, action) => {
    const { root, connect, cleanup } = await setup(properties);
    try {
      expect(root.querySelector('h1')?.textContent).toBe(heading);
      expect([...root.querySelectorAll('main button')].some(b => b.textContent === action)).toBe(true);
      expect(root.querySelector('main')?.textContent).not.toContain('设备连接已断开');
      expect(connect.mock.calls.filter(([service]) => service.startsWith('localfilesystem:'))).toHaveLength(1);
    } finally { cleanup(); }
  });

  it('requires the running binary to match the served artifact before reporting ready', async () => {
    const { root, cleanup } = await setup(installed.replace(`running_hash=${hash}`, `running_hash=${'b'.repeat(64)}`), true);
    expect(root.querySelector('h1')?.textContent).toBe('Engine 正在启动');
    cleanup();
  });

  it('does not claim latest Engine when the release manifest cannot be fetched', async () => {
    const { root, cleanup } = await setup(installed, true, false);
    expect(root.querySelector('h1')?.textContent).toBe('无法获取 Engine 版本');
    cleanup();
  });

  it('does not claim auto-start when the launcher is not executable', async () => {
    const { root, cleanup } = await setup(installed.replace('launcher=1', 'launcher=0'), true);
    expect(root.querySelector('h1')?.textContent).toBe('安装 AirSIM Engine');
    cleanup();
  });
});
