import { afterEach, describe, expect, it, vi } from 'vitest';
import { adbConfiguration, atInterfaces, enableEG25ADB, inspectEG25Bootstrap } from '../src/transport/eg25-bootstrap';
import { legacyADBResponse } from '../src/transport/qadbkey';
import { hasADB, moduleUSBFilters, moduleUSBManager } from '../src/transport/usb-discovery';
import { usbDevice } from './usb-fixtures';

const signal = () => new AbortController().signal;
afterEach(() => vi.useRealTimers());

describe('factory EG25 discovery and ADB preparation', () => {
  it('includes factory USB IDs without the ADB interface filter and preserves the user gesture', async () => {
    const first = usbDevice(); const second = usbDevice();
    const usb = { requestDevice: vi.fn().mockResolvedValue(first.raw), getDevices: async () => [first.raw, second.raw] };
    const manager = moduleUSBManager(usb as unknown as USB);
    const selecting = manager.requestDevice();
    expect(usb.requestDevice).toHaveBeenCalledWith({ filters: moduleUSBFilters });
    expect(moduleUSBFilters).toContainEqual({ vendorId: 0x2ca3, productId: 0x4006 });
    expect(hasADB(first.raw)).toBe(false);
    const selected = await selecting;
    const listed = await manager.getDevices();
    expect(listed[0].serial).toBe(selected?.serial);
    expect(listed[1].serial).not.toBe(listed[0].serial);
  });

  it('inspects factory modules read-only and closes the USB handle', async () => {
    const { raw, mock, commands } = usbDevice();
    await inspectEG25Bootstrap(raw, signal());
    expect(commands).toEqual(['AT', 'ATI', 'AT+QCFG="usbcfg"']);
    expect(mock.close).toHaveBeenCalled();
    expect(atInterfaces(raw)).toHaveLength(1);
    expect(atInterfaces(usbDevice(true).raw)).toHaveLength(0);
  });

  it('matches the published legacy challenge vector and rejects newer challenge formats', () => {
    expect(legacyADBResponse('12345678')).toBe('0jXKXQwSwMxYoeg');
    expect(() => legacyADBResponse('P1_NEW_FORMAT')).toThrow();
  });

  it('enables only ADB, keeps the original USB identity and sends one reboot', async () => {
    const { raw, commands } = usbDevice();
    await enableEG25ADB(raw, signal(), () => {});
    expect(commands).toContain('AT+QADBKEY="0jXKXQwSwMxYoeg"');
    expect(commands).toContain('AT+QCFG="usbcfg",0x2CA3,0x4006,1,1,1,1,1,1,0');
    expect(commands.filter(c => c === 'AT+CFUN=1,1')).toHaveLength(1);
    expect(commands).not.toContain('AT+QCFG="ims",1');
  });

  it('allows QDC507 data connections while still rejecting voice calls', async () => {
    const reply = '\r\n+CLCC: 1,1,0,1,0\r\n+CLCC: 2,1,0,1,0\r\nOK\r\n';
    const { raw, commands } = usbDevice(false, c => c === 'AT+CLCC' ? reply : undefined!);
    await enableEG25ADB(raw, signal(), () => {});
    expect(commands).toContain('AT+CFUN=1,1');
  });

  it('refuses other firmware, active calls, unsupported authorization and configuration drift', async () => {
    const cases = [
      ['ATI', '\r\nQuectel\r\nEG25-G\r\nOK\r\n', 'unsupported'],
      ['AT+CLCC', '\r\n+CLCC: 1,1,0,0,0\r\nOK\r\n', 'busy'],
      ['AT+CLCC', '\r\n+CLCC: malformed\r\nOK\r\n', 'adb_failed'],
      ['AT+QADBKEY?', '\r\n+QADBKEY: NEW_SCHEME\r\nOK\r\n', 'unsupported'],
      ['AT+QCFG="usbcfg"', '\r\n+QCFG: "usbcfg",0x2C7C,0x0125,1,1,1,1,1,0,0\r\nOK\r\n', 'unsupported'],
    ];
    for (const [command, reply, code] of cases) {
      const { raw, commands } = usbDevice(false, value => value === command ? reply : undefined!);
      await expect(enableEG25ADB(raw, signal(), () => {})).rejects.toMatchObject({ code });
      expect(commands.some(c => c.startsWith('AT+QCFG="usbcfg",'))).toBe(false);
      expect(commands).not.toContain('AT+CFUN=1,1');
    }
  });

  it('does not parse an unknown layout or inject a command from a USB configuration reply', () => {
    const { raw } = usbDevice();
    for (const reply of ['+QCFG: "usbcfg",1,2,3', '+QCFG: "usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,0;ATZ']) {
      expect(() => adbConfiguration(reply, raw)).toThrow();
    }
  });

  it('bounds a stalled AT read and closes the underlying USB device', async () => {
    vi.useFakeTimers();
    const { raw, mock } = usbDevice();
    mock.transferIn.mockImplementation(() => new Promise(() => {}));
    const result = expect(inspectEG25Bootstrap(raw, signal())).rejects.toMatchObject({ code: 'adb_failed' });
    await vi.advanceTimersByTimeAsync(4001);
    await result;
    expect(mock.close).toHaveBeenCalled();
  });
});
