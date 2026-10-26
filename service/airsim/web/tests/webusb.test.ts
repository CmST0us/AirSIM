import { describe, expect, it } from 'vitest';
import { parseHTTPResponse } from '../src/transport/webusb';

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
});
