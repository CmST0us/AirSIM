import { vi } from 'vitest';

export function usbDevice(adb = false, response?: (command: string) => string) {
  let queued = '';
  const commands: string[] = [];
  const alternate = (adb: boolean) => ({
    alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: adb ? 0x42 : 0,
    interfaceProtocol: adb ? 1 : 0, interfaceName: adb ? 'ADB' : 'AT',
    endpoints: [
      { endpointNumber: 1, direction: 'in', type: 'bulk', packetSize: 512 },
      { endpointNumber: 2, direction: 'out', type: 'bulk', packetSize: 512 },
    ],
  });
  const alt = alternate(adb);
  const intf = { interfaceNumber: adb ? 5 : 2, claimed: false, alternate: alt, alternates: [alt] };
  const config = { configurationValue: 1, interfaces: [intf] };
  const raw = {
    vendorId: 0x2ca3, productId: 0x4006, productName: 'Baiwang', serialNumber: '',
    configurations: [config], configuration: config, opened: false,
    open: vi.fn(async () => { raw.opened = true; }),
    close: vi.fn(async () => { raw.opened = false; intf.claimed = false; }),
    selectConfiguration: vi.fn(async () => {}), selectAlternateInterface: vi.fn(async () => {}),
    claimInterface: vi.fn(async () => { intf.claimed = true; }),
    transferOut: vi.fn(async (_endpoint: number, data: Uint8Array) => {
      const command = new TextDecoder().decode(data).trim();
      commands.push(command);
      queued = response?.(command) ?? ({
        ATI: '\r\nBaiwang\r\nQDC507\r\nRevision: QDC507GLEFM21\r\nOK\r\n',
        'AT+QCFG="usbcfg"': '\r\n+QCFG: "usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,0\r\nOK\r\n',
        'AT+QADBKEY?': '\r\n+QADBKEY: 12345678\r\nOK\r\n',
      }[command] ?? '\r\nOK\r\n');
      return { status: 'ok', bytesWritten: data.byteLength };
    }),
    transferIn: vi.fn(async () => {
      const buffer = new TextEncoder().encode(queued).buffer;
      queued = '';
      return { status: 'ok', data: new DataView(buffer) };
    }),
  };
  return { raw: raw as unknown as USBDevice, mock: raw, commands };
}
