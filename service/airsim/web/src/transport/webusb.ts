import { Adb, AdbDaemonTransport } from '@yume-chan/adb';
import AdbWebCredentialStore from '@yume-chan/adb-credential-web';
import {
  type AdbDaemonWebUsbDevice,
  AdbDaemonWebUsbDeviceManager,
} from '@yume-chan/adb-daemon-webusb';
import type { ConnectionResult, Device, DeviceTransport, FailureCode, Operation } from '../pairing';
import { TransportFailure } from '../pairing';

const socketPath = '/run/airsim-v2/control.sock';
const sessionKey = 'airsim.pairing-session';
const maxResponseBytes = 64 * 1024;
const localTimeout = 8_000;
const authTimeout = 20_000;

interface AgentStatus {
  module_id: string;
  public_key_base64: string;
  profile: string;
  configured: boolean;
  server_id: string;
  api_origin: string;
  media_origin: string;
  connected: boolean;
  certificate_expires_at: string | null;
}

interface Challenge {
  request_id: string;
  module_id: string;
  server_id: string;
  nonce: string;
  expires_at: string;
}

interface AgentProof {
  request_id: string;
  module_id: string;
  public_key_base64: string;
  proof_base64: string;
}

interface PairingSession {
  requestId: string;
  pollToken: string;
  deviceId: string;
  moduleId: string;
  serverId: string;
  nonce: string;
  expiresAt: string;
}

interface PairingStatus {
  request_id: string;
  module_id: string;
  state: 'awaiting_device' | 'awaiting_phone' | 'connected' | 'expired' | 'cancelled';
  expires_at: string;
  code: string;
  online: boolean;
}

interface WebUsbOptions {
  manager?: AdbDaemonWebUsbDeviceManager;
  storage?: Storage;
  fetch?: typeof fetch;
  serviceOrigin?: string;
}

interface Attachment {
  usb: AdbDaemonWebUsbDevice;
  adb: Adb;
  status: AgentStatus;
}

function abortError() {
  return new DOMException('The operation was aborted', 'AbortError');
}

async function withTimeout<T>(work: Promise<T>, signal: AbortSignal, milliseconds: number): Promise<T> {
  if (signal.aborted) throw abortError();
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new TransportFailure('disconnected')), milliseconds);
    const cancelled = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal.addEventListener('abort', cancelled, { once: true });
    work.then(value => {
      clearTimeout(timer);
      signal.removeEventListener('abort', cancelled);
      resolve(value);
    }, error => {
      clearTimeout(timer);
      signal.removeEventListener('abort', cancelled);
      reject(error);
    });
  });
}

function deviceView(usb: AdbDaemonWebUsbDevice, status?: AgentStatus): Device {
  const suffix = usb.serial.replace(/[^0-9A-Za-z]/g, '').slice(-8) || 'unknown';
  return {
    id: usb.serial,
    name: status?.profile === 'rm500u-embedded' ? 'RM500' : (usb.name || 'AirSIM 设备'),
    shortId: status?.module_id.slice(-8) || suffix,
  };
}

export function parseHTTPResponse(bytes: Uint8Array): { status: number; body: string } {
  const text = new TextDecoder().decode(bytes);
  const split = text.indexOf('\r\n\r\n');
  if (split < 0) throw new TransportFailure('failed');
  const head = text.slice(0, split).split('\r\n');
  const match = /^HTTP\/1\.[01] ([0-9]{3})/.exec(head.shift() || '');
  if (!match) throw new TransportFailure('failed');
  const headers = head.map(line => line.split(':', 2)).map(([key, value]) => [key.toLowerCase(), value.trim()]);
  let body = text.slice(split + 4);
  if (headers.some(([key]) => key === 'transfer-encoding' && /chunked/i.test(valueOf(headers, key)))) {
    body = decodeChunks(body);
  }
  return { status: Number(match[1]), body };
}

function valueOf(headers: string[][], key: string) {
  return headers.find(pair => pair[0] === key)?.[1] || '';
}

function decodeChunks(value: string) {
  let rest = value;
  const output: string[] = [];
  while (rest.length > 0) {
    const lineEnd = rest.indexOf('\r\n');
    if (lineEnd < 0) throw new TransportFailure('failed');
    const size = Number.parseInt(rest.slice(0, lineEnd), 16);
    if (!Number.isFinite(size)) throw new TransportFailure('failed');
    rest = rest.slice(lineEnd + 2);
    if (size === 0) return output.join('');
    if (rest.length < size + 2) throw new TransportFailure('failed');
    output.push(rest.slice(0, size));
    rest = rest.slice(size + 2);
  }
  throw new TransportFailure('failed');
}

async function localHTTP(adb: Adb, method: string, path: string, body?: unknown, signal?: AbortSignal) {
  const payload = body === undefined ? '' : JSON.stringify(body);
  const request = [
    `${method} ${path} HTTP/1.0`,
    'Host: localhost',
    'Accept: application/json',
    'Connection: close',
    ...(body === undefined ? [] : ['Content-Type: application/json', `Content-Length: ${new TextEncoder().encode(payload).length}`]),
    '',
    payload,
  ].join('\r\n');
  const socket = await adb.createSocket(`localfilesystem:${socketPath}`);
  const collect = async () => {
    const writer = socket.writable.getWriter();
    try {
      await writer.write(new TextEncoder().encode(request));
      await writer.close();
    } finally {
      writer.releaseLock();
    }
    const reader = socket.readable.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maxResponseBytes) throw new TransportFailure('failed');
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    const joined = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      joined.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return parseHTTPResponse(joined);
  };
  try {
    return signal ? await withTimeout(collect(), signal, localTimeout) : await collect();
  } finally {
    try { await socket.close(); } catch { /* Already closed by the device. */ }
  }
}

async function localJSON<T>(adb: Adb, method: string, path: string, body: unknown, signal: AbortSignal): Promise<{ status: number; body: T }> {
  const response = await localHTTP(adb, method, path, body, signal);
  try {
    return { status: response.status, body: JSON.parse(response.body) as T };
  } catch {
    throw new TransportFailure('failed');
  }
}

function validAgentStatus(value: unknown): value is AgentStatus {
  if (!value || typeof value !== 'object') return false;
  const status = value as Record<string, unknown>;
  return typeof status.module_id === 'string'
    && typeof status.public_key_base64 === 'string'
    && typeof status.profile === 'string'
    && typeof status.configured === 'boolean'
    && typeof status.server_id === 'string'
    && typeof status.api_origin === 'string'
    && typeof status.media_origin === 'string'
    && typeof status.connected === 'boolean'
    && (status.certificate_expires_at === null || typeof status.certificate_expires_at === 'string');
}

function validChallenge(value: unknown, operation: Operation): value is Challenge {
  if (!value || typeof value !== 'object') return false;
  const challenge = value as Record<string, unknown>;
  const remaining = typeof challenge.expires_at === 'string'
    ? Date.parse(challenge.expires_at) - Date.now() : NaN;
  return challenge.request_id === operation.id
    && typeof challenge.module_id === 'string'
    && typeof challenge.server_id === 'string'
    && typeof challenge.nonce === 'string'
    && /^[0-9a-f]{64}$/.test(challenge.nonce)
    && typeof challenge.expires_at === 'string'
    && remaining > 0 && remaining <= 305_000;
}

function resultFromStatus(value: PairingStatus): ConnectionResult {
  switch (value.state) {
    case 'awaiting_phone':
      return /^[0-9]{8}$/.test(value.code)
        ? { state: 'awaiting_phone', code: value.code, expiresAt: value.expires_at }
        : { state: 'failed' };
    case 'connected':
      return { state: 'connected', online: value.online };
    case 'expired':
      return { state: 'expired' };
    case 'cancelled':
      return { state: 'cancelled' };
    default:
      return { state: 'pending' };
  }
}

function failureForStatus(status: number, code?: string): FailureCode {
  if (status === 401) return 'unknown';
  if (status === 404) return 'not_ready';
  if (status === 409) return code === 'pairing_conflict' ? 'busy' : 'failed';
  if (status === 410) return 'not_ready';
  if (status === 429) return 'busy';
  return 'failed';
}

export function createWebUsbTransport(options: WebUsbOptions = {}): DeviceTransport | undefined {
  const manager = options.manager || AdbDaemonWebUsbDeviceManager.BROWSER;
  if (!manager) return undefined;
  const activeManager = manager;
  const storage = options.storage || window.sessionStorage;
  const request = options.fetch || fetch;
  const serviceOrigin = (options.serviceOrigin || (import.meta.env.VITE_AIRSIM_PAIRING_ORIGIN as string | undefined) || '')
    .replace(/\/$/, '');
  const credentials = new AdbWebCredentialStore('AirSIM');
  const attachments = new Map<string, Attachment>();
  const usbDevices = new Map<string, AdbDaemonWebUsbDevice>();
  const service = (path: string) => serviceOrigin + path;

  function save(session: PairingSession) {
    storage.setItem(sessionKey, JSON.stringify(session));
  }

  function load(): PairingSession | undefined {
    const raw = storage.getItem(sessionKey);
    if (!raw) return;
    try {
      const value = JSON.parse(raw) as PairingSession;
      return typeof value.requestId === 'string' && typeof value.pollToken === 'string'
        && typeof value.deviceId === 'string' && typeof value.moduleId === 'string'
        && typeof value.serverId === 'string' && typeof value.nonce === 'string'
        && typeof value.expiresAt === 'string' ? value : undefined;
    } catch {
      return;
    }
  }

  function clear(requestId: string) {
    if (load()?.requestId === requestId) storage.removeItem(sessionKey);
  }

  async function serviceJSON(path: string, init: RequestInit, expected: number[] = [200], signal?: AbortSignal): Promise<unknown> {
    let response: Response;
    try {
      response = await request(service(path), {
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        ...init,
        signal,
        headers: { Accept: 'application/json', ...init.headers },
      });
    } catch {
      throw new TransportFailure('unknown');
    }
    if (response.status === 410) return { state: 'expired' };
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength > maxResponseBytes) throw new TransportFailure('failed');
    let body: unknown;
    try { body = JSON.parse(new TextDecoder().decode(bytes)); }
    catch { throw new TransportFailure('failed'); }
    if (!expected.includes(response.status)) {
      const code = body && typeof body === 'object' && typeof (body as Record<string, unknown>).error === 'string'
        ? String((body as Record<string, unknown>).error) : undefined;
      throw new TransportFailure(failureForStatus(response.status, code));
    }
    return body;
  }

  async function attach(usb: AdbDaemonWebUsbDevice, signal: AbortSignal): Promise<Attachment> {
    const current = attachments.get(usb.serial);
    if (current) return current;
    try {
      const connection = await withTimeout(usb.connect(), signal, authTimeout);
      const transport = await withTimeout(AdbDaemonTransport.authenticate({
        serial: usb.serial,
        connection,
        credentialStore: credentials,
      }), signal, authTimeout);
      const adb = new Adb(transport);
      const status = await readStatus(adb, signal);
      const attachment = { usb, adb, status };
      attachments.set(usb.serial, attachment);
      return attachment;
    } catch (error) {
      if (error instanceof TransportFailure) throw error;
      if (error instanceof DOMException && error.name === 'AbortError') throw new TransportFailure('cancelled');
      if (error instanceof Error && /busy|claim/i.test(error.name + ' ' + error.message)) throw new TransportFailure('busy');
      throw new TransportFailure('disconnected');
    }
  }

  async function readStatus(adb: Adb, signal: AbortSignal): Promise<AgentStatus> {
    let response;
    try {
      response = await localJSON<unknown>(adb, 'GET', '/v2/local/pairing', undefined, signal);
    } catch (error) {
      if (error instanceof TransportFailure && ['cancelled', 'disconnected'].includes(error.code)) throw error;
      if (error instanceof TransportFailure) throw new TransportFailure('not_ready');
      throw new TransportFailure('disconnected');
    }
    if (!validAgentStatus(response.body) || !response.body.configured) {
      throw new TransportFailure('not_ready');
    }
    if (response.body.profile !== 'rm500u-embedded') throw new TransportFailure('unsupported');
    if (!response.body.server_id || !response.body.api_origin || !response.body.media_origin) throw new TransportFailure('not_ready');
    return response.body;
  }

  async function getUsb(id: string, signal?: AbortSignal): Promise<AdbDaemonWebUsbDevice> {
    const known = usbDevices.get(id);
    if (known) return known;
    const devices = await activeManager.getDevices();
    if (signal?.aborted) throw new TransportFailure('cancelled');
    for (const usb of devices) {
      usbDevices.set(usb.serial, usb);
      if (usb.serial === id) return usb;
    }
    throw new TransportFailure('disconnected');
  }

  async function approve(
    attachment: Attachment,
    operation: Operation,
    existing: PairingSession | undefined,
    signal: AbortSignal,
  ): Promise<ConnectionResult> {
    const pollToken = existing?.pollToken || crypto.getRandomValues(new Uint8Array(32)).reduce(
      (value, byte) => value + byte.toString(16).padStart(2, '0'), '');
    let session = existing;
    if (!session) {
      const challengeBody = await serviceJSON('/v2/pairing/challenges', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ request_id: operation.id, module_id: attachment.status.module_id, poll_token: pollToken }),
      }, [200, 201], signal);
      if (!validChallenge(challengeBody, operation)) throw new TransportFailure('failed');
      if (challengeBody.server_id !== attachment.status.server_id || !(await validOrigin(attachment.status.api_origin))) {
        throw new TransportFailure('not_ready');
      }
      session = {
        requestId: operation.id, pollToken, deviceId: operation.device.id,
        moduleId: attachment.status.module_id, serverId: challengeBody.server_id,
        nonce: challengeBody.nonce, expiresAt: challengeBody.expires_at,
      };
      save(session);
    }
    const proofResponse = await localJSON<unknown>(attachment.adb, 'POST', '/v2/local/pairing/authorize', {
      request_id: session.requestId,
      server_id: session.serverId,
      module_id: session.moduleId,
      nonce: session.nonce,
      expires_at: session.expiresAt,
      poll_token_hash: await sha256(session.pollToken),
    }, signal);
    if (proofResponse.status === 410) return { state: 'expired' };
    if (proofResponse.status !== 200 || !validProof(proofResponse.body, session)) {
      throw new TransportFailure(failureForStatus(proofResponse.status));
    }
    const body = await serviceJSON(`/v2/pairing/${session.requestId}/approve`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.pollToken}` },
      body: JSON.stringify({
        public_key_base64: proofResponse.body.public_key_base64,
        proof_base64: proofResponse.body.proof_base64,
      }),
    }, [200], signal);
    return resultFromStatus(body as PairingStatus);
  }

  return {
    async listGrantedDevices(signal) {
      const devices = await activeManager.getDevices();
      const output: Device[] = [];
      for (const usb of devices) {
        usbDevices.set(usb.serial, usb);
        output.push(deviceView(usb, attachments.get(usb.serial)?.status));
      }
      if (signal.aborted) throw new TransportFailure('cancelled');
      return output;
    },

    requestDevice(signal) {
      // Keep requestDevice in the same user-activation task.
      return activeManager.requestDevice().then(usb => {
        if (!usb) throw new TransportFailure('cancelled');
        usbDevices.set(usb.serial, usb);
        if (signal.aborted) throw new TransportFailure('cancelled');
        return deviceView(usb);
      }, error => {
        if (error instanceof DOMException && error.name === 'AbortError') throw new TransportFailure('cancelled');
        throw new TransportFailure('failed');
      });
    },

    async inspect(device, signal) {
      const usb = await getUsb(device.id, signal);
      const attachment = await attach(usb, signal);
      return deviceView(usb, attachment.status);
    },

    async connect(operation, signal) {
      const usb = await getUsb(operation.device.id, signal);
      const attachment = await attach(usb, signal);
      const stored = load();
      const existing = stored?.requestId === operation.id && stored.deviceId === operation.device.id
        ? stored : undefined;
      return approve(attachment, operation, existing, signal);
    },

    async status(operation, signal) {
      const session = load();
      if (!session || session.requestId !== operation.id || session.deviceId !== operation.device.id) {
        throw new TransportFailure('unknown');
      }
      const body = await serviceJSON(`/v2/pairing/${session.requestId}`, {
        method: 'GET',
        headers: { Authorization: `Bearer ${session.pollToken}` },
      }, [200], signal);
      const result = resultFromStatus(body as PairingStatus);
      if (result.state === 'connected' || result.state === 'expired' || result.state === 'cancelled') clear(session.requestId);
      return result;
    },

    async cancel(operation, signal) {
      const session = load();
      if (!session || session.requestId !== operation.id || session.deviceId !== operation.device.id) {
        throw new TransportFailure('unknown');
      }
      const body = await serviceJSON(`/v2/pairing/${session.requestId}`, {
        method: 'DELETE',
        headers: { Authorization: `Bearer ${session.pollToken}` },
      }, [200], signal);
      const result = resultFromStatus(body as PairingStatus);
      if (result.state === 'cancelled' || result.state === 'expired' || result.state === 'connected') clear(session.requestId);
      return result;
    },

    async disconnect(device) {
      const attachment = attachments.get(device.id);
      attachments.delete(device.id);
      if (attachment) await attachment.adb.close().catch(() => {});
    },
  };
}

function validProof(value: unknown, session: PairingSession): value is AgentProof {
  if (!value || typeof value !== 'object') return false;
  const proof = value as Record<string, unknown>;
  return proof.request_id === session.requestId
    && proof.module_id === session.moduleId
    && typeof proof.public_key_base64 === 'string'
    && typeof proof.proof_base64 === 'string';
}

async function validOrigin(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && !url.username && !url.password && url.pathname === '/'
      && !url.search && !url.hash;
  } catch {
    return false;
  }
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
