import { TransportFailure } from '../pairing';
import { legacyADBResponse } from './qadbkey';
import { eg25USBFilters } from './usb-discovery';

const timeout = 4_000;
const maxResponse = 16 * 1024;
const encoder = new TextEncoder();

export function atInterfaces(device: USBDevice) {
  if (!eg25USBFilters.some(f => f.vendorId === device.vendorId && f.productId === device.productId)) return [];
  return device.configurations.flatMap(configuration => configuration.interfaces.flatMap(intf =>
    intf.alternates.flatMap(alternate => {
      // QDC507 AT/modem only. Never probe DIAG, NMEA, QMI or network endpoints.
      if (![2, 3].includes(intf.interfaceNumber) || alternate.interfaceClass !== 0xff
        || alternate.interfaceSubclass !== 0 || alternate.interfaceProtocol !== 0) return [];
      const input = alternate.endpoints.find(e => e.type === 'bulk' && e.direction === 'in');
      const output = alternate.endpoints.find(e => e.type === 'bulk' && e.direction === 'out');
      return input && output ? [{ configuration, intf, alternate, input, output }] : [];
    })));
}

export function adbConfiguration(response: string, device: Pick<USBDevice, 'vendorId' | 'productId'>): string[] {
  const matches = [...response.matchAll(/^\s*\+QCFG:\s*"usbcfg",([^\r\n]+)\s*$/gm)];
  if (matches.length !== 1) throw new TransportFailure('unsupported', '无法核对模块 USB 配置。');
  const fields = matches[0][1].split(',').map(value => value.trim());
  if (fields.length !== 9 || !fields.slice(0, 2).every(value => /^(0x[0-9a-f]+|[0-9]+)$/i.test(value))
    || !fields.slice(2).every(value => /^[01]$/.test(value))
    || Number(fields[0]) !== device.vendorId || Number(fields[1]) !== device.productId) {
    throw new TransportFailure('unsupported', 'USB 配置与所选模块不匹配，未作修改。');
  }
  return fields;
}

async function bounded<T>(device: USBDevice, signal: AbortSignal, work: () => Promise<T>): Promise<T> {
  if (signal.aborted) throw new TransportFailure('cancelled');
  let timer: ReturnType<typeof setTimeout> | undefined;
  let abort = () => {};
  try {
    return await Promise.race([work(), new Promise<never>((_, reject) => {
      const stop = (code: 'cancelled' | 'adb_failed') => {
        // Closing terminates the pending bulk read; never reuse it for another command.
        void device.close().catch(() => {});
        reject(new TransportFailure(code, code === 'adb_failed' ? '模块 AT 接口未及时响应。' : undefined));
      };
      timer = setTimeout(() => stop('adb_failed'), timeout);
      abort = () => stop('cancelled');
      signal.addEventListener('abort', abort, { once: true });
      if (signal.aborted) abort();
    })]);
  } finally {
    clearTimeout(timer);
    signal.removeEventListener('abort', abort);
  }
}

async function session(device: USBDevice, signal: AbortSignal) {
  const candidates = atInterfaces(device);
  if (!candidates.length) throw new TransportFailure('unsupported', '没有找到此固件支持的 USB AT 接口。');
  let failure: unknown;
  for (const candidate of candidates) {
    try {
      await bounded(device, signal, async () => {
        if (!device.opened) await device.open();
        if (device.configuration?.configurationValue !== candidate.configuration.configurationValue) {
          await device.selectConfiguration(candidate.configuration.configurationValue);
        }
        try { await device.claimInterface(candidate.intf.interfaceNumber); }
        catch { throw new TransportFailure('busy'); }
        if (candidate.intf.alternate.alternateSetting !== candidate.alternate.alternateSetting) {
          await device.selectAlternateInterface(candidate.intf.interfaceNumber, candidate.alternate.alternateSetting);
        }
      });
      const command = (value: string) => bounded(device, signal, async () => {
        const bytes = encoder.encode(value + '\r');
        const written = await device.transferOut(candidate.output.endpointNumber, bytes);
        if (written.status !== 'ok' || written.bytesWritten !== bytes.length) throw new TransportFailure('adb_failed');
        let text = '';
        const decoder = new TextDecoder();
        for (;;) {
          const result = await device.transferIn(candidate.input.endpointNumber, candidate.input.packetSize);
          if (result.status !== 'ok' || !result.data) throw new TransportFailure('adb_failed');
          text += decoder.decode(result.data, { stream: true });
          if (text.length > maxResponse) throw new TransportFailure('adb_failed');
          const lines = text.split(/[\r\n]+/).map(line => line.trim());
          if (lines.some(line => line === 'ERROR' || /^\+(CME|CMS) ERROR:/.test(line))) {
            // Do not include commands/responses: they can contain an unlock response or URCs.
            throw new TransportFailure('adb_failed', '模块拒绝了初始化操作；未继续执行后续步骤。');
          }
          if (lines.includes('OK')) return text;
        }
      });
      await command('AT');
      return command;
    } catch (error) {
      await device.close().catch(() => {});
      if (signal.aborted) throw new TransportFailure('cancelled');
      failure = error;
    }
  }
  throw failure instanceof TransportFailure ? failure : new TransportFailure('adb_failed');
}

async function inspect(command: (value: string) => Promise<string>, device: USBDevice) {
  const identity = (await command('ATI')).split(/[\r\n]+/).map(line => line.trim());
  if (!identity.includes('QDC507') || !identity.includes('Revision: QDC507GLEFM21')) {
    throw new TransportFailure('unsupported', '此初始化流程只支持 QDC507GLEFM21 固件。');
  }
  return adbConfiguration(await command('AT+QCFG="usbcfg"'), device);
}

export async function inspectEG25Bootstrap(device: USBDevice, signal: AbortSignal) {
  try { await inspect(await session(device, signal), device); }
  finally { await device.close().catch(() => {}); }
}

export async function enableEG25ADB(device: USBDevice, signal: AbortSignal, progress: (message: string) => void) {
  let configurationWritten = false;
  try {
    const command = await session(device, signal);
    progress('正在核对 EG25 固件与 USB 配置…');
    const before = await inspect(command, device);
    // A reboot must not interrupt a live cellular call. Keep the reply out of logs.
    const calls = (await command('AT+CLCC')).split(/[\r\n]+/).map(line => line.trim()).filter(line => line.startsWith('+CLCC:'));
    for (const call of calls) {
      const fields = /^\+CLCC:\s*\d+,\s*[01],\s*[0-6],\s*(\d+),\s*[01](?:,.*)?$/.exec(call);
      if (!fields) throw new TransportFailure('adb_failed', '无法核对模块通话状态。');
      // QDC507 reports persistent data connections as mode=1; these are not
      // voice calls (the Agent's EG25 parser applies the same distinction).
      if (fields[1] !== '1') throw new TransportFailure('busy', '请结束模块上的通话后再初始化。');
    }
    progress('正在开启模块 ADB…');
    const challenge = await command('AT+QADBKEY?');
    const matches = [...challenge.matchAll(/^\s*\+QADBKEY:\s*([0-9]{8})\s*$/gm)];
    if (matches.length !== 1) throw new TransportFailure('unsupported', '此固件需要厂商 ADB 授权，未修改 USB 配置。');
    await command(`AT+QADBKEY="${legacyADBResponse(matches[0][1])}"`);
    const target = [...before];
    target[7] = '1';
    // Preserve the observed VID/PID, AT, modem, network and UAC settings.
    configurationWritten = true;
    await command(`AT+QCFG="usbcfg",${target.join(',')}`);
    const actual = adbConfiguration(await command('AT+QCFG="usbcfg"'), device);
    if (actual.some((value, index) => index < 2 ? Number(value) !== Number(target[index])
      : index === 7 ? value !== before[index] && value !== target[index] : value !== target[index])) {
      throw new TransportFailure('adb_failed', '模块配置回读不一致，未自动重启。');
    }
    progress('ADB 已配置，正在重启模块…');
    // Re-enumeration may close USB before the reboot's OK arrives. Never replay it.
    try { await command('AT+CFUN=1,1'); }
    catch {
      throw new TransportFailure('adb_reconnect', 'ADB 已配置。请保持供电，等待模块重启后重新选择；若未重启，请拔插模块电源。');
    }
  } catch (error) {
    if (error instanceof TransportFailure) throw error;
    throw new TransportFailure(configurationWritten ? 'adb_reconnect' : 'adb_failed');
  } finally {
    await device.close().catch(() => {});
  }
}
