import { md5 } from '@noble/hashes/legacy.js';
import { concatBytes, utf8ToBytes } from '@noble/hashes/utils.js';

// QDC507's legacy protocol uses the first 15 characters of Unix MD5-crypt.
// This public firmware constant is not an AirSIM credential. Derived responses
// stay in memory and must never enter UI errors, logs, storage or HTTP requests.
export function legacyADBResponse(challenge: string): string {
  if (!/^[0-9]{8}$/.test(challenge)) throw new Error('Unsupported ADB challenge');
  const password = utf8ToBytes('SH_adb_quectel');
  const salt = utf8ToBytes(challenge);
  const alternate = md5(concatBytes(password, salt, password));
  const initial = md5.create().update(password).update(utf8ToBytes('$1$')).update(salt);
  initial.update(alternate.subarray(0, password.length));
  for (let count = password.length; count > 0; count >>= 1) {
    initial.update(count & 1 ? new Uint8Array([0]) : password.subarray(0, 1));
  }
  let digest = initial.digest();
  for (let i = 0; i < 1000; i++) {
    const round = md5.create().update(i & 1 ? password : digest);
    if (i % 3) round.update(salt);
    if (i % 7) round.update(password);
    digest = round.update(i & 1 ? digest : password).digest();
  }
  const alphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  let encoded = '';
  for (const [high, middle, low, count] of [[0, 6, 12, 4], [1, 7, 13, 4], [2, 8, 14, 4], [3, 9, 15, 4]]) {
    let value = (digest[high] << 16) | (digest[middle] << 8) | digest[low];
    for (let n = 0; n < count; n++, value >>>= 6) encoded += alphabet[value & 63];
  }
  return encoded.slice(0, 15);
}
