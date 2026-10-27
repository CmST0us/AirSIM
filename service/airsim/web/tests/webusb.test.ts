import { describe, expect, it } from 'vitest';
import { challengeRequest, createEngineBundle, failureForStatus, parseHTTPResponse } from '../src/transport/webusb';
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

  it('builds a regular-file tar bundle for the persistent Agent and launcher', () => {
    const agent = encoder.encode('agent');
    const launcher = encoder.encode('launcher');
    const audio = encoder.encode('audio');
    const bundle = createEngineBundle(agent, launcher, audio, '0123456789abcdef', 'install');
    const decoder = new TextDecoder();
    expect(decoder.decode(bundle.slice(0, 100)).replace(/\0+$/, ''))
      .toBe('releases/0123456789abcdef/.airsim-agent.new');
    expect(decoder.decode(bundle.slice(512, 517))).toBe('agent');

    const second = 1024;
    expect(decoder.decode(bundle.slice(second, second + 100)).replace(/\0+$/, '')).toBe('.run-agent.sh.new');
    expect(decoder.decode(bundle.slice(second + 512, second + 520))).toBe('launcher');
    const third = 2048;
    expect(decoder.decode(bundle.slice(third, third + 100)).replace(/\0+$/, '')).toBe('.airsim-audiod.new');
    expect(decoder.decode(bundle.slice(third + 512, third + 517))).toBe('audio');
    const fourth = 3072;
    expect(decoder.decode(bundle.slice(fourth, fourth + 100)).replace(/\0+$/, '')).toBe('.airsim-install.sh.new');
    expect(decoder.decode(bundle.slice(fourth + 512, fourth + 519))).toBe('install');
    const header = bundle.slice(0, 512);
    const storedChecksum = Number.parseInt(decoder.decode(header.slice(148, 154)), 8);
    header.fill(0x20, 148, 156);
    expect(storedChecksum).toBe(header.reduce((sum, value) => sum + value, 0));
  });
});
