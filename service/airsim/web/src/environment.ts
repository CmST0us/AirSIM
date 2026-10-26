export interface Environment { mobile: boolean; supported: boolean }

export function browserEnvironment(): Environment {
  const mobile = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent)
    || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  return { mobile, supported: window.isSecureContext && 'usb' in navigator };
}
