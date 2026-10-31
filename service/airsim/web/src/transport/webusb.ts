import { platforms, isPlatform, detectPlatform, hardwareScript, parseProperties, type PlatformID } from './platform';
import { Adb, AdbDaemonTransport } from '@yume-chan/adb';
import AdbWebCredentialStore from '@yume-chan/adb-credential-web';
import {
  type AdbDaemonWebUsbDevice,
  AdbDaemonWebUsbDeviceManager,
} from '@yume-chan/adb-daemon-webusb';
import type { ConnectionResult, Device, DeviceTransport, EngineStatus, FailureCode, Operation } from '../pairing';
import { TransportFailure } from '../pairing';

const socketPath = '/run/airsim-v2/control.sock';
const sessionKey = 'airsim.pairing-session';
const maxResponseBytes = 64 * 1024;
const localTimeout = 8_000;
const authTimeout = 20_000;
const installTimeout = 240_000;
const engineRoot = '/engine';

interface EngineArtifact {
  path: string;
  size: number;
  sha256: string;
}

interface EngineManifest {
  schema_version: number;
  version: string;
  os: string;
  arch: string;
  profile: PlatformID;
  platform?: EngineArtifact[];
  licenses: EngineArtifact[];
  agent: EngineArtifact;
  launcher: EngineArtifact;
  audio: EngineArtifact;
}

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

interface AgentHealth {
  status: string;
  version: string;
  agent_boot_id: string;
}

interface Challenge {
  request_id: string;
  module_id: string;
  server_id: string;
  nonce: string;
  expires_at: string;
  replace_existing?: boolean;
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
  replaceExisting?: boolean;
}

interface PairingStatus {
  request_id: string;
  module_id: string;
  state: 'awaiting_device' | 'awaiting_phone' | 'connected' | 'expired' | 'cancelled';
  expires_at: string;
  code: string;
  online: boolean;
  replace_existing?: boolean;
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

function deviceView(usb: AdbDaemonWebUsbDevice, status?: AgentStatus, engine?: EngineStatus): Device {
  const suffix = usb.serial.replace(/[^0-9A-Za-z]/g, '').slice(-8) || 'unknown';
  return {
    id: usb.serial,
    name: status && isPlatform(status.profile) ? platforms[status.profile].name : (engine?.profile && isPlatform(engine.profile) ? platforms[engine.profile].name : (usb.name || 'AirSIM 设备')),
    shortId: status?.module_id.slice(-8) || suffix,
    engine,
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

function validEngineArtifact(value: unknown): value is EngineArtifact {
  if (!value || typeof value !== 'object') return false;
  const artifact = value as Record<string, unknown>;
  return typeof artifact.path === 'string'
    && /^[A-Za-z0-9._-]+$/.test(artifact.path)
    && Number.isSafeInteger(artifact.size)
    && Number(artifact.size) > 0
    && Number(artifact.size) <= 32 * 1024 * 1024
    && typeof artifact.sha256 === 'string'
    && /^[a-f0-9]{64}$/.test(artifact.sha256);
}

export function validEngineManifest(value: unknown): value is EngineManifest {
  if (!value || typeof value !== 'object') return false;
  const manifest = value as Record<string, unknown>;
  return manifest.schema_version === 1
    && typeof manifest.version === 'string'
    && /^[0-9A-Za-z.+-]+$/.test(manifest.version)
    && manifest.os === 'linux'
    && typeof manifest.profile === 'string' && isPlatform(manifest.profile)
    && manifest.arch === platforms[manifest.profile].arch
    && (manifest.profile === 'rm500u-embedded' ? manifest.platform === undefined : Array.isArray(manifest.platform) && manifest.platform.length === 7 && manifest.platform.every(validEngineArtifact) && ['airsim_data11.ko', 'qdc507_aprv3.ko', 'qdc507_voice.ko', 'COPYING-GPL-2.0', 'MODULE-REPORT.md', 'airsim_data11.c', 'isrgrootx1.pem'].every(name => (manifest.platform as EngineArtifact[]).some(file => file.path === name)))
    && Array.isArray(manifest.licenses) && manifest.licenses.length === 4
    && manifest.licenses.every(validEngineArtifact)
    && ['LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'LC3-LICENSE.txt'].every(name => (manifest.licenses as EngineArtifact[]).some(file => file.path === name))
    && validEngineArtifact(manifest.agent)
    && validEngineArtifact(manifest.launcher)
    && validEngineArtifact(manifest.audio)
    && manifest.agent.path === 'airsim-agent'
    && manifest.launcher.path === 'run-agent.sh'
    && manifest.audio.path === 'airsim-audiod';
}

export function prepareEngineStorageScript(profile: PlatformID, release: string, requiredBytes: number): string {
  const requiredKiB = Math.ceil(requiredBytes / 1024) + 512;
  return `
set -eu
base=${platforms[profile].base}
release=${release}
current=
current_link="$(readlink "$base/current" 2>/dev/null || true)"
if [ -n "$current_link" ]; then
  current="\${current_link##*/}"
fi
for directory in $(ls -1dt "$base"/releases/* 2>/dev/null); do
  [ -d "$directory" ] || continue
  name="\${directory##*/}"
  [ "$name" = "$current" ] && continue
  rm -rf "$directory"
done
available_kib="$(df -Pk "$base" | awk 'NR == 2 { print $4 }')"
if [ -z "$available_kib" ] || [ "$available_kib" -lt ${requiredKiB} ]; then
  echo AIRSIM_ENGINE_STORAGE_SHORT
  exit 1
fi
`;
}

export function installEngineScript(manifest: EngineManifest, release: string): string {
  return `
set -eu
base=${platforms[manifest.profile].base}
release_dir="$base/releases/${release}"
agent="$release_dir/.airsim-agent.new"
installed_agent="$release_dir/airsim-agent"
launcher="$base/.run-agent.sh.new"
audio="$base/.airsim-audiod.new"
audio_release="$base/audio-releases/audio-${manifest.audio.sha256.slice(0, 16)}"
root_was_ro=0
if grep -q ' / ubifs ro,' /proc/mounts 2>/dev/null; then
  root_was_ro=1
fi
restore_root() {
  if [ "$root_was_ro" = 1 ]; then
    mount -o remount,ro / >/dev/null 2>&1 || true
  fi
}
trap restore_root EXIT HUP INT TERM

chmod 700 "$agent"
chmod 700 "$launcher"
chmod 700 "$audio"
test -x "$launcher"
agent_hash="$(sha256sum "$agent" | awk '{print $1}')"
launcher_hash="$(sha256sum "$launcher" | awk '{print $1}')"
audio_hash="$(sha256sum "$audio" | awk '{print $1}')"
[ "$agent_hash" = "${manifest.agent.sha256}" ]
[ "$launcher_hash" = "${manifest.launcher.sha256}" ]
[ "$audio_hash" = "${manifest.audio.sha256}" ]
${[...(manifest.platform || []), ...manifest.licenses].map(file => `test "$(sha256sum "$base/.${file.path}.new" | awk '{print $1}')" = "${file.sha256}"`).join('\n')}
mkdir -p "$base/config" "$base/state" "$base/platform" "$base/licenses"
${manifest.licenses.map(file => `mv -f "$base/.${file.path}.new" "$base/licenses/${file.path}"`).join('\n')}
${(manifest.platform || []).map(file => `mv -f "$base/.${file.path}.new" "$base/platform/${file.path}"`).join('\n')}
chmod 700 "$base/config" "$base/state"
random_seed="$base/config/random.seed"
if [ ! -f "$random_seed" ] || [ "$(wc -c <"$random_seed")" -ne 64 ]; then
  dd if=/dev/urandom of="$base/config/random.seed.tmp" bs=64 count=1 2>/dev/null
  chmod 600 "$base/config/random.seed.tmp"
  mv -f "$base/config/random.seed.tmp" "$random_seed"
fi
chmod 600 "$random_seed"
test "$(wc -c <"$random_seed")" -eq 64
mv -f "$agent" "$installed_agent"
current_audio_hash="$(sha256sum "$base/audio-current/airsim-audiod" 2>/dev/null | awk '{print $1}' || true)"
if [ "$current_audio_hash" != "${manifest.audio.sha256}" ]; then
  mkdir -p "$audio_release"
  chmod 700 "$base/audio-releases" "$audio_release"
  mv -f "$audio" "$audio_release/airsim-audiod"
  chmod 700 "$audio_release/airsim-audiod"
  rm -f "$base/.audio-current.next"
  ln -s "audio-releases/audio-${manifest.audio.sha256.slice(0, 16)}" "$base/.audio-current.next"
  rm -f "$base/audio-current"
  mv -f "$base/.audio-current.next" "$base/audio-current"
else
  rm -f "$audio"
fi
test -x "$base/audio-current/airsim-audiod"

previous="$(readlink "$base/current" 2>/dev/null || true)"
rm -f "$base/current.next"
ln -s "releases/${release}" "$base/current.next"
rm -f "$base/current"
mv -f "$base/current.next" "$base/current"
for d in "$base"/releases/*; do
  [ -d "$d" ] || continue
  name="\${d##*/}"
  link="releases/$name"
  if [ "$link" = "$previous" ] || [ "$name" = "${release}" ]; then
    continue
  fi
  rm -f "$d/airsim-agent" 2>/dev/null || true
  rmdir "$d" 2>/dev/null || true
done
mv -f "$launcher" "$base/run-agent.sh"
chmod 700 "$base/run-agent.sh"

mount -o remount,rw /
if [ ! -f /etc/inittab.airsim-backup ]; then
  cp /etc/inittab /etc/inittab.airsim-backup
fi
tmp=/etc/inittab.airsim-new
{
  grep -v '^asm:' /etc/inittab 2>/dev/null || true
  echo 'asm:12345:respawn:${platforms[manifest.profile].base}/run-agent.sh'
} > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" /etc/inittab
test "$(grep -c '^asm:12345:respawn:${platforms[manifest.profile].base}/run-agent.sh$' /etc/inittab)" -eq 1
sync
restore_root
trap - EXIT HUP INT TERM

pids="$(pidof airsim-agent 2>/dev/null || true)"
if [ -n "$pids" ]; then
  kill -TERM $pids 2>/dev/null || true
fi
echo AIRSIM_ENGINE_INSTALLED
kill -HUP 1
sleep 1
`;
}

function bootstrapEngineScript(profile: PlatformID, release: string): string {
  return `
set -eu
base=${platforms[profile].base}
release_dir="$base/releases/${release}"
sh "$base/.airsim-install.sh.new"
`;
}

function pause(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) {
      reject(new TransportFailure('cancelled'));
      return;
    }
    const timer = setTimeout(() => {
      signal.removeEventListener('abort', abort);
      resolve();
    }, milliseconds);
    const abort = () => {
      clearTimeout(timer);
      reject(new TransportFailure('cancelled'));
    };
    signal.addEventListener('abort', abort, { once: true });
  });
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
    && remaining > 0 && remaining <= 305_000
    && (operation.replaceExisting === true
      ? challenge.replace_existing === true
      : challenge.replace_existing === false || challenge.replace_existing === undefined);
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

export function failureForStatus(status: number, code?: string): FailureCode {
  if (status === 401) return 'unknown';
  if (status === 404) return 'not_ready';
  if (status === 409) {
    if (code === 'module_already_paired') return 'paired';
    return code === 'pairing_conflict' ? 'busy' : 'failed';
  }
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
  const inspectedDevices = new Map<string, Device>();
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
        && typeof value.expiresAt === 'string'
        && (value.replaceExisting === undefined || typeof value.replaceExisting === 'boolean') ? value : undefined;
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

  async function shellText(adb: Adb, script: string, signal: AbortSignal, timeout = localTimeout): Promise<string> {
    let socket: Awaited<ReturnType<Adb['createSocket']>> | undefined;
    try {
      const activeSocket = await adb.createSocket(`shell:${script}`);
      socket = activeSocket;
      const collect = async () => {
        const reader = activeSocket.readable.getReader();
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
        const output = new Uint8Array(size);
        let offset = 0;
        for (const chunk of chunks) {
          output.set(chunk, offset);
          offset += chunk.byteLength;
        }
        return new TextDecoder().decode(output);
      };
      return await withTimeout(collect(), signal, timeout);
    } catch (error) {
      if (error instanceof TransportFailure) throw error;
      throw new TransportFailure('unknown', error instanceof Error ? `${error.name}: ${error.message}` : String(error));
    } finally {
      if (socket) {
        try { await socket.close(); } catch { /* Already closed by the device. */ }
      }
    }
  }

  async function execText(adb: Adb, script: string, signal: AbortSignal, timeout = localTimeout): Promise<string> {
    try {
      return await withTimeout(
        adb.subprocess.noneProtocol.spawnWaitText([script]),
        signal,
        timeout,
      );
    } catch (error) {
      if (error instanceof TransportFailure) throw error;
      throw new TransportFailure('unknown', error instanceof Error ? `${error.name}: ${error.message}` : String(error));
    }
  }

  async function bootstrapEngine(adb: Adb, profile: PlatformID, release: string, signal: AbortSignal): Promise<string> {
    const script = bootstrapEngineScript(profile, release);
    let output = '';
    const errors: string[] = [];
    try { output = await execText(adb, script, signal, installTimeout); }
    catch (error) {
      if (signal.aborted) throw error;
      if (error instanceof Error) errors.push(`${error.name}: ${error.message}`);
    }
    if (!output.includes('AIRSIM_ENGINE_INSTALLED') && errors.length === 0 && !signal.aborted) {
      try { output += await shellText(adb, script, signal, installTimeout); }
      catch (error) {
        if (signal.aborted) throw error;
        if (error instanceof Error) errors.push(`${error.name}: ${error.message}`);
      }
    }
    if (!output.includes('AIRSIM_ENGINE_INSTALLED')) {
      if (errors.length && !signal.aborted) return '';
      const detail = [output.trim(), ...errors].filter(Boolean).join('\n').slice(-1000)
        || '设备未返回安装结果。';
      throw new TransportFailure('install_failed', detail);
    }
    return output;
  }

  async function loadEngineManifest(profile: PlatformID, signal: AbortSignal): Promise<EngineManifest> {
    let response: Response;
    try {
      response = await request(service(`${engineRoot}/${profile}/manifest.json`), {
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        signal,
        headers: { Accept: 'application/json' },
      });
    } catch {
      throw new TransportFailure('install_failed');
    }
    if (!response.ok) throw new TransportFailure('install_failed');
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength > 16 * 1024) throw new TransportFailure('install_failed');
    let value: unknown;
    try { value = JSON.parse(new TextDecoder().decode(bytes)); }
    catch { throw new TransportFailure('install_failed'); }
    if (!validEngineManifest(value) || value.profile !== profile) throw new TransportFailure('install_failed');
    return value;
  }

  async function identify(adb: Adb, signal: AbortSignal): Promise<PlatformID | undefined> {
    return detectPlatform(parseProperties(await shellText(adb, hardwareScript, signal)));
  }

  async function inspectEngine(adb: Adb, signal: AbortSignal): Promise<EngineStatus> {
    const profile = await identify(adb, signal);
    if (!profile) return { state: 'unavailable', compatible: false };
    const base = platforms[profile].base;
    const manifest = await loadEngineManifest(profile, signal).catch(error => {
      if (signal.aborted) throw error;
      return undefined;
    });
    const supportFiles = manifest ? [...(manifest.platform || []).map(file => ({...file, directory: 'platform'})), ...manifest.licenses.map(file => ({...file, directory: 'licenses'}))] : [];
    const output = await shellText(adb, `
agent=${base}/current/airsim-agent
printf 'agent=%s\\n' "$(test -x "$agent" && echo 1 || echo 0)"
printf 'launcher_hash=%s\\n' "$(sha256sum ${base}/run-agent.sh 2>/dev/null | awk '{print $1}')"
printf 'audio_hash=%s\\n' "$(sha256sum ${base}/audio-current/airsim-audiod 2>/dev/null | awk '{print $1}')"
printf 'hash=%s\\n' "$(test -r "$agent" && sha256sum "$agent" | awk '{print $1}' || true)"
${supportFiles.map(file => `printf '${file.path}=%s\\n' "$(sha256sum ${base}/${file.directory}/${file.path} 2>/dev/null | awk '{print $1}')"`).join('\n')}
printf 'autostart=%s\\n' "$(grep -c '^asm:12345:respawn:${base}/run-agent.sh$' /etc/inittab 2>/dev/null || true)"
`, signal);
    const values = parseProperties(output);
    const compatible = true;
    const installed = values.get('agent') === '1';
    const autostart = values.get('autostart') === '1';
    const currentHash = values.get('hash') || undefined;
    let installedVersion: string | undefined;
    let healthReady = false;
    try {
      const health = await localJSON<AgentHealth>(adb, 'GET', '/healthz', undefined, signal);
      if (health.status === 200 && health.body?.status === 'ok'
        && typeof health.body.version === 'string') {
        installedVersion = health.body.version;
        healthReady = true;
      }
    } catch {
      // A missing socket is expected before the first deployment.
    }
    let state: EngineStatus['state'];
    if (!compatible) state = 'unavailable';
    else if (!installed) state = 'missing';
    else if (!autostart) state = 'incomplete';
    else if (manifest && (currentHash !== manifest.agent.sha256 || values.get('launcher_hash') !== manifest.launcher.sha256 || values.get('audio_hash') !== manifest.audio.sha256 || supportFiles.some(file => values.get(file.path) !== file.sha256))) state = 'outdated';
    else state = healthReady ? 'ready' : 'starting';
    return {
      state,
      compatible,
      profile,
      installedVersion,
      targetVersion: manifest?.version,
    };
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
      const attachment = { usb, adb };
      attachments.set(usb.serial, attachment);
      return attachment;
    } catch (error) {
      if (error instanceof TransportFailure) throw error;
      if (error instanceof DOMException && error.name === 'AbortError') throw new TransportFailure('cancelled');
      if (error instanceof Error && /busy|claim/i.test(error.name + ' ' + error.message)) throw new TransportFailure('busy');
      throw new TransportFailure('disconnected');
    }
  }

  async function releaseAttachment(attachment: Attachment) {
    attachments.delete(attachment.usb.serial);
    await attachment.adb.close().catch(() => {});
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
    if (!isPlatform(response.body.profile)) throw new TransportFailure('unsupported');
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

  async function fetchEngineArtifact(profile: PlatformID, artifact: EngineArtifact, signal: AbortSignal): Promise<Uint8Array> {
    let response: Response;
    try {
      response = await request(service(`${engineRoot}/${profile}/${artifact.path}`), {
        cache: 'no-store',
        credentials: 'omit',
        redirect: 'error',
        signal,
      });
    } catch {
      throw new TransportFailure('install_failed');
    }
    if (!response.ok) throw new TransportFailure('install_failed');
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength !== artifact.size) throw new TransportFailure('install_failed');
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    const hash = [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
    if (hash !== artifact.sha256) throw new TransportFailure('install_failed');
    return bytes;
  }

  async function pushFile(adb: Adb, filename: string, bytes: Uint8Array, signal: AbortSignal): Promise<boolean> {
    let socket: Awaited<ReturnType<Adb['createSocket']>> | undefined;
    try {
      socket = await withTimeout(adb.createSocket('sync:'), signal, authTimeout);
      const activeSocket = socket;
      const writer = activeSocket.writable.getWriter();
      const reader = activeSocket.readable.getReader();
      try {
        const transfer = async () => {
          let buffered = new Uint8Array();
          const writeRequest = async (id: string, value: Uint8Array) => {
            const header = new Uint8Array(8);
            header.set(new TextEncoder().encode(id), 0);
            new DataView(header.buffer).setUint32(4, value.byteLength, true);
            await writer.write(header);
            if (value.byteLength) await writer.write(value);
          };
          const readExact = async (length: number) => {
            while (buffered.byteLength < length) {
              const { done, value } = await reader.read();
              if (done) {
                if (buffered.byteLength === 0) return undefined;
                throw new TransportFailure('install_failed', `设备响应不完整（${buffered.byteLength}/${length} 字节）`);
              }
              const joined = new Uint8Array(buffered.byteLength + value.byteLength);
              joined.set(buffered, 0);
              joined.set(value, buffered.byteLength);
              buffered = joined;
            }
            const output = buffered.slice(0, length);
            buffered = buffered.slice(length);
            return output;
          };

          const path = `${filename},${(0o100000 | 0o700).toString()}`;
          await writeRequest('SEND', new TextEncoder().encode(path));
          for (let offset = 0; offset < bytes.byteLength; offset += 64 * 1024) {
            await writeRequest('DATA', bytes.subarray(offset, Math.min(bytes.byteLength, offset + 64 * 1024)));
          }
          const done = new Uint8Array(8);
          done.set(new TextEncoder().encode('DONE'), 0);
          new DataView(done.buffer).setUint32(4, Math.floor(Date.now() / 1000), true);
          await writer.write(done);

          const responseBytes = await readExact(4);
          if (!responseBytes) return false;
          const response = new TextDecoder().decode(responseBytes);
          if (response === 'FAIL') {
            const lengthBytes = await readExact(4);
            if (!lengthBytes) throw new TransportFailure('install_failed', '设备写入了空的失败响应。');
            const length = new DataView(lengthBytes.buffer).getUint32(0, true);
            const messageBytes = await readExact(length);
            if (!messageBytes) throw new TransportFailure('install_failed', '设备写入了不完整的失败响应。');
            const message = new TextDecoder().decode(messageBytes);
            throw new TransportFailure('install_failed', message || '设备拒绝写入文件。');
          }
          if (response !== 'OKAY') {
            throw new TransportFailure('install_failed', `设备返回未知写入状态：${JSON.stringify(response)}`);
          }
          return true;
        };
        return await withTimeout(transfer(), signal, installTimeout);
      } finally {
        writer.releaseLock();
        reader.releaseLock();
      }
    } catch (error) {
      if (error instanceof TransportFailure) throw error;
      throw new TransportFailure('install_failed', error instanceof Error ? `${error.name}: ${error.message}` : undefined);
    } finally {
      if (socket) {
        try { await socket.close(); } catch { /* Already closed by the device. */ }
      }
    }
  }

  async function waitForAgent(initial: Attachment, signal: AbortSignal): Promise<{ attachment: Attachment; status?: AgentStatus }> {
    const deadline = Date.now() + 90_000;
    let attachment: Attachment | undefined = initial;
    while (Date.now() < deadline) {
      if (signal.aborted) throw new TransportFailure('cancelled');
      try {
        if (!attachment) {
          // USB composition changes re-enumerate the same selected module.
          const matches = (await activeManager.getDevices()).filter(usb => usb.serial === initial.usb.serial);
          // Chrome grants serial-less devices access only until USB disconnects.
          if (matches.length === 0 && !initial.usb.raw.serialNumber) {
            throw new TransportFailure('install_reconnect');
          }
          if (matches.length !== 1) { await pause(1_000, signal); continue; }
          usbDevices.set(matches[0].serial, matches[0]);
          attachment = await attach(matches[0], signal);
        }
        const health = await localJSON<AgentHealth>(attachment.adb, 'GET', '/healthz', undefined, signal);
        if (health.status === 200 && health.body?.status === 'ok'
          && typeof health.body.version === 'string' && typeof health.body.agent_boot_id === 'string') {
          try { return { attachment, status: await readStatus(attachment.adb, signal) }; }
          catch (error) {
            if (error instanceof TransportFailure && error.code === 'not_ready') return { attachment };
            throw error;
          }
        }
      } catch (error) {
        if (signal.aborted) throw error;
        if (error instanceof TransportFailure && error.code === 'install_reconnect') throw error;
        if (attachment) await releaseAttachment(attachment);
        attachment = undefined;
      }
      await pause(1_000, signal);
    }
    throw new TransportFailure('install_failed', 'Engine 启动超时，请重新选择设备检查状态。');
  }

  async function approve(
    attachment: Attachment,
    operation: Operation,
    existing: PairingSession | undefined,
    signal: AbortSignal,
  ): Promise<ConnectionResult> {
    const status = await readStatus(attachment.adb, signal);
    const pollToken = existing?.pollToken || crypto.getRandomValues(new Uint8Array(32)).reduce(
      (value, byte) => value + byte.toString(16).padStart(2, '0'), '');
    let session = existing;
    if (!session) {
      const replaceExisting = operation.replaceExisting === true;
      const challengeBody = await serviceJSON('/v2/pairing/challenges', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(challengeRequest(operation, status.module_id, pollToken)),
      }, [200, 201], signal);
      if (!validChallenge(challengeBody, operation)) throw new TransportFailure('failed');
      if (challengeBody.server_id !== status.server_id || !(await validOrigin(status.api_origin))) {
        throw new TransportFailure('not_ready');
      }
      session = {
        requestId: operation.id, pollToken, deviceId: operation.device.id,
        moduleId: status.module_id, serverId: challengeBody.server_id,
        nonce: challengeBody.nonce, expiresAt: challengeBody.expires_at,
        replaceExisting,
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
        output.push(inspectedDevices.get(usb.serial) || deviceView(usb));
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
        const device = deviceView(usb);
        inspectedDevices.set(usb.serial, device);
        return device;
      }, error => {
        if (error instanceof DOMException && error.name === 'AbortError') throw new TransportFailure('cancelled');
        throw new TransportFailure('failed');
      });
    },

    async inspect(device, signal) {
      const usb = await getUsb(device.id, signal);
      const attachment = await attach(usb, signal);
      try {
        const engine = await inspectEngine(attachment.adb, signal);
        let status: AgentStatus | undefined;
        try { status = await readStatus(attachment.adb, signal); }
        catch (error) {
          if (error instanceof TransportFailure && ['cancelled', 'disconnected'].includes(error.code)) throw error;
        }
        const inspected = deviceView(usb, status, engine);
        inspectedDevices.set(usb.serial, inspected);
        return inspected;
      } catch (error) {
        await releaseAttachment(attachment);
        throw error;
      }
    },

    async install(device, signal, progress) {
      const usb = await getUsb(device.id, signal);
      let attachment = await attach(usb, signal);
      let stage = '准备安装';
      try {
        const profile = await identify(attachment.adb, signal);
        if (!profile) throw new TransportFailure('unsupported');
        const base = platforms[profile].base;
        stage = '准备持久化存储';
        progress('正在准备持久化存储…');
        await shellText(attachment.adb, `mkdir -p ${base}/releases && chmod 700 ${base} ${base}/releases`, signal);
        stage = '下载 Engine 发布包';
        const manifest = await loadEngineManifest(profile, signal);
        progress('正在下载 AirSIM Engine…');
        const artifacts = [manifest.agent, manifest.launcher, manifest.audio, ...(manifest.platform || []), ...manifest.licenses];
        const contents = await Promise.all(artifacts.map(file => fetchEngineArtifact(profile, file, signal)));
        const release = manifest.agent.sha256.slice(0, 16);
        const releaseDirectory = `${base}/releases/${release}`;
        const installScript = installEngineScript(manifest, release);
        stage = '整理模块存储';
        progress('正在整理模块存储…');
        const storage = await shellText(attachment.adb,
          prepareEngineStorageScript(profile, release, contents.reduce((n, file) => n + file.byteLength, 0)), signal);
        if (storage.includes('AIRSIM_ENGINE_STORAGE_SHORT')) throw new TransportFailure('install_failed', '模块空间不足；当前运行版本已保留。');
        stage = '写入模块持久存储';
        progress('正在写入模块持久存储…');
        await shellText(attachment.adb, `mkdir -p ${releaseDirectory} && chmod 700 ${releaseDirectory}`, signal);
        const staged = [ `${releaseDirectory}/.airsim-agent.new`, `${base}/.run-agent.sh.new`, `${base}/.airsim-audiod.new`,
          ...[...(manifest.platform || []), ...manifest.licenses].map(file => `${base}/.${file.path}.new`) ];
        const scriptBytes = new TextEncoder().encode(installScript);
        contents.push(scriptBytes); staged.push(`${base}/.airsim-install.sh.new`);
        for (let i = 0; i < contents.length; i++) {
          await pushFile(attachment.adb, staged[i], contents[i], signal);
          const actual = (await shellText(attachment.adb, `sha256sum ${staged[i]} | awk '{print $1}'`, signal)).trim();
          if (actual !== await sha256Bytes(contents[i])) throw new TransportFailure('install_failed', '模块文件校验失败。');
        }
        stage = '执行持久化安装脚本';
        progress('正在执行持久化安装脚本…');
        await bootstrapEngine(attachment.adb, profile, release, signal);
        stage = '等待 Engine 启动';
        progress('等待 AirSIM Engine 启动…');
        const result = await waitForAgent(attachment, signal);
        attachment = result.attachment;
        const status = result.status;
        stage = '读取安装结果';
        const engine = await inspectEngine(attachment.adb, signal);
        if (engine.state !== 'ready') throw new TransportFailure('install_failed', 'Engine 文件或自启动状态未通过安装验证。');
        const installed = deviceView(usb, status, engine);
        inspectedDevices.set(usb.serial, installed);
        return installed;
      } catch (error) {
        await releaseAttachment(attachment);
        const detail = error instanceof TransportFailure
          ? error.detail
          : error instanceof Error ? `${error.name}: ${error.message}` : String(error);
        const message = `${stage}：${detail || '未返回错误信息'}`;
        if (error instanceof TransportFailure) throw new TransportFailure(error.code, error.code === 'install_reconnect' ? undefined : message);
        throw new TransportFailure('install_failed', message);
      }
    },

    async connect(operation, signal) {
      const usb = await getUsb(operation.device.id, signal);
      const attachment = await attach(usb, signal);
      const stored = load();
      const existing = stored?.requestId === operation.id && stored.deviceId === operation.device.id
        && (stored.replaceExisting === true) === (operation.replaceExisting === true)
        ? stored : undefined;
      return approve(attachment, operation, existing, signal);
    },

    async status(operation, signal) {
      const session = load();
      if (!session || session.requestId !== operation.id || session.deviceId !== operation.device.id
        || (session.replaceExisting === true) !== (operation.replaceExisting === true)) {
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
      if (!session || session.requestId !== operation.id || session.deviceId !== operation.device.id
        || (session.replaceExisting === true) !== (operation.replaceExisting === true)) {
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
      if (attachment) await releaseAttachment(attachment);
    },
  };
}

export function challengeRequest(operation: Operation, module: string, pollToken: string) {
  return {
    request_id: operation.id,
    module_id: module,
    poll_token: pollToken,
    ...(operation.replaceExisting === true ? { replace_existing: true } : {}),
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
  return sha256Bytes(new TextEncoder().encode(value));
}

async function sha256Bytes(value: Uint8Array) {
  const digest = await crypto.subtle.digest('SHA-256', new Uint8Array(value).buffer);
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
