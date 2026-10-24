#!/usr/bin/env python3
"""Owner-only local API bridge. Never prints request/response credentials.
Use an explicit Unix socket, or a controller-created loopback ADB forward.
"""
import argparse
import http.client
import json
import os
import pathlib
import socket
import stat
import sys
import tempfile
import urllib.parse

class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=5)
        self.path = path
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--endpoint', required=True, help='unix:/run/airsim-v2/control.sock or http://127.0.0.1:PORT')
    p.add_argument('--operation', required=True, choices=['prepare', 'activate', 'status', 'media-stats'])
    p.add_argument('--input')
    p.add_argument('--output', required=True)
    a = p.parse_args()
    output = pathlib.Path(a.output)
    if output.exists() or output.is_symlink():
        raise ValueError('output_exists')
    body = None
    if a.operation not in ('status', 'media-stats'):
        if not a.input:
            raise ValueError('input_required')
        source = pathlib.Path(a.input)
        info = source.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 32768:
            raise ValueError('input_permissions')
        body = source.read_bytes()
        json.loads(body)
    elif a.input:
        raise ValueError('unexpected_input')
    if a.endpoint.startswith('unix:'):
        conn = UnixHTTP(a.endpoint[5:])
    else:
        u = urllib.parse.urlsplit(a.endpoint)
        if u.scheme != 'http' or u.hostname != '127.0.0.1' or not u.port or u.username or u.password or u.path or u.query or u.fragment:
            raise ValueError('loopback_endpoint_required')
        conn = http.client.HTTPConnection('127.0.0.1', u.port, timeout=5)
    try:
        path = '/v2/local/cloud' + ('' if a.operation == 'status' else '/' + a.operation)
        conn.request('GET' if body is None else 'POST', path, body=body, headers={'Content-Type': 'application/json', 'Connection': 'close'})
        reply = conn.getresponse()
        payload = reply.read(65537)
        if not 200 <= reply.status < 300 or len(payload) > 65536:
            raise ValueError('local_api_rejected')
        json.loads(payload)
        fd, name = tempfile.mkstemp(prefix='.cloud-result-', dir=output.parent)
        try:
            with os.fdopen(fd, 'wb') as f:
                os.fchmod(f.fileno(), 0o600)
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
            os.link(name, output)  # refuse an intervening overwrite/symlink
            parent = os.open(output.parent, os.O_RDONLY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
        finally:
            os.unlink(name)
    finally:
        conn.close()

if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('cloud_local_failed', file=sys.stderr)
        sys.exit(1)
