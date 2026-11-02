import { AdbDaemonWebUsbDevice, AdbDefaultInterfaceFilter, matchFilters } from '@yume-chan/adb-daemon-webusb';

export const eg25USBFilters = [
  { vendorId: 0x2ca3, productId: 0x4006 },
  { vendorId: 0x2c7c, productId: 0x0125 },
];
export const moduleUSBFilters = [AdbDefaultInterfaceFilter, ...eg25USBFilters];

export interface ModuleUSBDevice {
  raw: USBDevice;
  serial: string;
  name: string;
  connect(): ReturnType<AdbDaemonWebUsbDevice['connect']>;
}
export interface ModuleUSBManager {
  requestDevice(): Promise<ModuleUSBDevice | undefined>;
  getDevices(): Promise<ModuleUSBDevice[]>;
}

export function hasADB(device: USBDevice): boolean {
  return Boolean(matchFilters(device, [AdbDefaultInterfaceFilter]));
}

/** Include factory EG25 IDs without requiring an ADB interface in the picker. */
export function moduleUSBManager(usb: USB): ModuleUSBManager {
  const identities = new WeakMap<USBDevice, string>();
  function wrap(raw: USBDevice): ModuleUSBDevice | undefined {
    const adbInterface = matchFilters(raw, [AdbDefaultInterfaceFilter]);
    if (!adbInterface && !eg25USBFilters.some(f => f.vendorId === raw.vendorId && f.productId === raw.productId)) return;
    // VID/PID is not an identity: two serial-less EG25s must have separate handles.
    let id = identities.get(raw);
    if (!id) { id = crypto.randomUUID(); identities.set(raw, id); }
    return {
      raw, serial: id, name: raw.productName || 'AirSIM 设备',
      connect: () => {
        if (!adbInterface) throw new Error('ADB interface unavailable');
        return new AdbDaemonWebUsbDevice(raw, adbInterface, usb).connect();
      },
    };
  }
  return {
    async requestDevice() {
      try { return wrap(await usb.requestDevice({ filters: moduleUSBFilters })); }
      catch (error) {
        if (error instanceof DOMException && error.name === 'NotFoundError') return;
        throw error;
      }
    },
    async getDevices() {
      return (await usb.getDevices()).map(wrap).filter((d): d is ModuleUSBDevice => d !== undefined);
    },
  };
}
