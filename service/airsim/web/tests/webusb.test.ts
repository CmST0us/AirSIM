import { describe, expect, it } from 'vitest';
import { challengeRequest, failureForStatus, parseHTTPResponse } from '../src/transport/webusb';
import { device } from './fixtures';

const encoder = new TextEncoder();

describe('local Agent HTTP transport', () => {
  it('reads a close-delimited HTTP/1.0 JSON response', () => {
    const response = parseHTTPResponse(encoder.encode(
      'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"configured":true}',
    ));
    expect(response).toEqual({ status: 200, body: '{"configured":true}' });
  });

  it('decodes a chunked response without exposing framing', () => {
    const response = parseHTTPResponse(encoder.encode(
      'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{"a"\r\n5\r\n:"b"}\r\n0\r\n\r\n',
    ));
    expect(response).toEqual({ status: 200, body: '{"a":"b"}' });
  });

  it('rejects malformed and incomplete local responses', () => {
    expect(() => parseHTTPResponse(encoder.encode('not http'))).toThrow();
    expect(() => parseHTTPResponse(encoder.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{}'))).toThrow();
  });

  it('adds the explicit replacement flag only for a reset request', () => {
    const normal = challengeRequest({ id: 'normal', device }, 'module', 'poll');
    const replacement = challengeRequest({ id: 'replace', device, replaceExisting: true }, 'module', 'poll');
    expect(normal).not.toHaveProperty('replace_existing');
    expect(replacement.replace_existing).toBe(true);
  });

  it('turns an existing-phone response into the reset flow', () => {
    expect(failureForStatus(409, 'module_already_paired')).toBe('paired');
    expect(failureForStatus(409, 'pairing_conflict')).toBe('busy');
  });

});
