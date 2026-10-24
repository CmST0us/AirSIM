#!/usr/bin/env python3
"""Isolated loopback test; no device, ADB or cloud access."""
import http.server
import json
import pathlib
import subprocess
import sys
import tempfile
import threading

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        payload = json.dumps({'configured': False}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

with tempfile.TemporaryDirectory() as directory:
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    try:
        script = pathlib.Path(__file__).with_name('cloud_local.py')
        output = pathlib.Path(directory) / 'status.json'
        command = [sys.executable, str(script), '--endpoint', 'http://127.0.0.1:' + str(server.server_port), '--operation', 'status', '--output', str(output)]
        result = subprocess.run(command, capture_output=True, timeout=10)
        assert result.returncode == 0 and not result.stdout and not result.stderr
        assert output.stat().st_mode & 0o777 == 0o600
        assert json.loads(output.read_text()) == {'configured': False}
        result = subprocess.run(command, capture_output=True, timeout=10)
        assert result.returncode == 1 and not result.stdout and result.stderr == b'cloud_local_failed\n'
        command[3] = 'http://example.invalid'
        command[-1] = str(pathlib.Path(directory) / 'refused.json')
        result = subprocess.run(command, capture_output=True, timeout=10)
        assert result.returncode == 1 and not result.stdout
    finally:
        server.shutdown()
        server.server_close()
        worker.join()
print('local bootstrap output permissions, no-overwrite and loopback restriction passed')
