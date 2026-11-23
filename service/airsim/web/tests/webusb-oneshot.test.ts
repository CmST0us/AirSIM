import { afterEach, describe, expect, it, vi } from 'vitest';
import { AdbDaemonTransport, type AdbTransport } from '@yume-chan/adb';
import { createWebUsbTransport } from '../src/transport/webusb';
import { PairingController } from '../src/controller';
import { TransportFailure } from '../src/pairing';
import { adapter, device, environment, operationStore } from './fixtures';
import { usbDevice } from './usb-fixtures';

const moduleId = '33333333-3333-4333-8333-333333333333';
const serverId = '11111111-1111-4111-8111-111111111111';
const hash = 'a'.repeat(64);

function socket(text: string) {
  let received = '';
  return {
    readable: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(text)); c.close(); } }),
    writable: new WritableStream({ write(chunk) { received += new TextDecoder().decode(chunk); } }),
    close: vi.fn(async () => {}), closed: Promise.resolve(undefined), service: '',
    body: () => received,
  };
}

afterEach(() => { vi.restoreAllMocks(); sessionStorage.clear(); });

describe('one-shot cloud provisioning and pairing', () => {
  it('auto-provisions an unconfigured module during connect and returns an 8-digit pairing code', async () => {
    let configured = false;
    let lastReqId = '';
    const calls: string[] = [];
    const { raw } = usbDevice(true);
    const usb = { raw, serial: 'oneshot-dev', name: 'Baiwang', connect: vi.fn(async () => ({} as never)) };

    const connect = vi.fn(async (service: string) => {
      if (service.startsWith('shell:')) {
        calls.push(`shell:${service.includes('date -u -s') ? 'clock-sync' : 'other'}`);
        return socket('');
      }
      if (service !== 'localfilesystem:/run/airsim-v2/control.sock') {
        throw new Error('unexpected service: ' + service);
      }
      let reqBuf = '';
      let controller!: ReadableStreamDefaultController<Uint8Array>;
      const respond = (status: number, body: unknown) => {
        controller.enqueue(new TextEncoder().encode(`HTTP/1.0 ${status} OK\r\nContent-Type: application/json\r\n\r\n${JSON.stringify(body)}`));
        controller.close();
      };
      return {
        readable: new ReadableStream<Uint8Array>({ start(c) { controller = c; } }),
        writable: new WritableStream<Uint8Array>({
          write(chunk) { reqBuf += new TextDecoder().decode(chunk); },
          close() {
            const firstLine = reqBuf.split('\r\n')[0];
            const [, path] = firstLine.split(' ');
            const rawBody = reqBuf.split('\r\n\r\n')[1] || '';
            calls.push(`local:${path}`);
            if (path === '/v2/local/pairing') {
              respond(200, configured ? {
                module_id: moduleId, public_key_base64: 'cHVi', profile: 'eg25-qdc507',
                configured: true, server_id: serverId, api_origin: 'https://airsim.eric3u.cc',
                media_origin: 'https://airsim.eric3u.cc', connected: true, certificate_expires_at: '2027-02-21T00:00:00Z',
              } : {
                module_id: moduleId, public_key_base64: 'cHVi', profile: 'eg25-qdc507',
                configured: false, server_id: '', api_origin: '', media_origin: '',
                connected: false, certificate_expires_at: null,
              });
            } else if (path === '/v2/local/cloud/prepare') {
              const p = JSON.parse(rawBody);
              lastReqId = p.request_id;
              respond(200, {
                request_id: p.request_id, module_id: moduleId, public_key_base64: 'cHVi',
                csr_pem: '-----BEGIN CERTIFICATE REQUEST-----\nabc\n-----END CERTIFICATE REQUEST-----\n',
                proof_base64: 'cHJvb2Y=',
              });
            } else if (path === '/v2/local/cloud/activate') {
              const b = JSON.parse(rawBody);
              expect(b.request_id).toBe(lastReqId);
              configured = true;
              respond(200, { configured: true });
            } else if (path === '/v2/local/pairing/authorize') {
              const a = JSON.parse(rawBody);
              respond(200, { request_id: a.request_id, module_id: moduleId, public_key_base64: 'cHVi', proof_base64: 'cGFpcg==' });
            } else {
              respond(404, { error: 'not_found' });
            }
          },
        }),
        close: vi.fn(async () => {}), closed: Promise.resolve(undefined), service,
      };
    });

    const backend = { connect, close: vi.fn(async () => {}), disconnected: new Promise<void>(() => {}),
      clientFeatures: [], banner: { features: [] }, serial: 'oneshot-dev', maxPayloadSize: 4096 } as unknown as AdbTransport;
    vi.spyOn(AdbDaemonTransport, 'authenticate').mockResolvedValue(backend as AdbDaemonTransport);

    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      calls.push(`ecs:${url}`);
      const body = init?.body ? JSON.parse(String(init.body)) : {};
      if (url.endsWith('/v2/pairing/provision/prepare')) {
        return new Response(JSON.stringify({
          prepare: {
            request_id: body.request_id, server_id: serverId,
            api_origin: 'https://airsim.eric3u.cc', device_origin: 'https://device.airsim.eric3u.cc',
            media_origin: 'https://airsim.eric3u.cc',
            device_ca_pem: '-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----\n',
            server_ca_pem: '', nonce: hash, expires_at: new Date(Date.now() + 300_000).toISOString(),
          },
          prepare_token: hash,
        }), { status: 200 });
      }
      if (url.endsWith('/v2/pairing/provision/issue')) {
        return new Response(JSON.stringify({
          request_id: body.prepare.request_id, server_id: serverId, module_id: moduleId,
          certificate_pem: '-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n',
          receipt_base64: 'cmVjZWlwdA==',
        }), { status: 201 });
      }
      if (url.endsWith('/v2/pairing/challenges')) {
        return new Response(JSON.stringify({
          request_id: body.request_id, module_id: moduleId, server_id: serverId,
          nonce: hash, expires_at: new Date(Date.now() + 300_000).toISOString(),
        }), { status: 201 });
      }
      if (url.endsWith('/approve')) {
        return new Response(JSON.stringify({
          request_id: 'op-1', module_id: moduleId, state: 'awaiting_phone',
          expires_at: new Date(Date.now() + 300_000).toISOString(), code: '87654321', online: true,
        }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: 'unexpected' }), { status: 404 });
    });

    const transport = createWebUsbTransport({
      manager: { requestDevice: async () => usb, getDevices: async () => [usb] },
      storage: sessionStorage, fetch: fetchMock, serviceOrigin: 'https://airsim.eric3u.cc',
    })!;
    const picked = await transport.requestDevice(new AbortController().signal);
    const result = await transport.connect({ id: '44444444-4444-4444-8444-444444444444', device: picked }, new AbortController().signal);
    expect(result).toMatchObject({ state: 'awaiting_phone', code: '87654321' });
    expect(calls).toEqual([
      'shell:clock-sync',
      'local:/v2/local/pairing',
      'ecs:https://airsim.eric3u.cc/v2/pairing/provision/prepare',
      'shell:clock-sync',
      'local:/v2/local/cloud/prepare',
      'ecs:https://airsim.eric3u.cc/v2/pairing/provision/issue',
      'local:/v2/local/cloud/activate',
      'local:/v2/local/pairing',
      'ecs:https://airsim.eric3u.cc/v2/pairing/challenges',
      'shell:clock-sync',
      'local:/v2/local/pairing/authorize',
      'ecs:https://airsim.eric3u.cc/v2/pairing/44444444-4444-4444-8444-444444444444/approve',
    ]);
    // Keep unused helper referenced cleanly if extended later
    expect(socket('')).toBeDefined();
  });

  it('auto-resumes one-shot pairing after USB install_reconnect and starting wait', async () => {
    vi.useFakeTimers();
    try {
      const transport = adapter();
      const controller = new PairingController({ environment, transport, operationId: () => 'op-oneshot' });
      await controller.start();

      const missing = { ...device, engine: { state: 'missing' as const, compatible: true } };
      const starting = { ...device, engine: { state: 'starting' as const, compatible: true } };
      const ready = { ...device, engine: { state: 'ready' as const, compatible: true } };
      transport.inspect
        .mockResolvedValueOnce(missing)
        .mockResolvedValueOnce(starting)
        .mockResolvedValueOnce(ready);
      transport.install.mockRejectedValueOnce(new TransportFailure('install_reconnect'));
      transport.connect.mockResolvedValueOnce({
        state: 'awaiting_phone', code: '11223344', expiresAt: new Date(Date.now() + 300_000).toISOString(),
      });

      await controller.requestDevice();
      await controller.oneShot();
      expect(controller.state).toMatchObject({ kind: 'failed', code: 'install_reconnect' });

      const reselect = controller.requestDevice();
      await vi.advanceTimersByTimeAsync(1600);
      await reselect;
      expect(transport.connect).toHaveBeenCalledTimes(1);
      expect(controller.state).toMatchObject({ kind: 'awaiting_phone', code: '11223344' });
    } finally {
      vi.useRealTimers();
    }
  });

  it('surfaces provision_failed with detail and clears pending store instead of trapping in unknown', async () => {
    const transport = adapter();
    const store = operationStore();
    const controller = new PairingController({ environment, transport, store, operationId: () => 'op-prov-fail' });
    await controller.start();
    await controller.requestDevice();
    transport.connect.mockRejectedValueOnce(new TransportFailure('provision_failed', '模块拒绝生成云端开通凭证（HTTP 400）。'));
    await controller.connect();
    expect(controller.state).toMatchObject({
      kind: 'failed',
      code: 'provision_failed',
      detail: '模块拒绝生成云端开通凭证（HTTP 400）。',
    });
    expect(store.load()).toBeUndefined();
  });
});
