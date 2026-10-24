"""Record only R1's sanitized snapshot and process resource evidence."""
import json
import pathlib
import re
import sys
import time
from adb_device import Device

serial, pid, executable, output = sys.argv[1:]
if not pid.isdigit():
    raise ValueError('invalid PID')
d = Device(serial)
if d.shell('readlink /proc/' + pid + '/exe') != executable:
    raise RuntimeError('process identity mismatch')
metadata = {"binary": executable, "pid": int(pid), "sha256": d.shell("sha256sum " + executable).split()[0]}
records = []
start = time.monotonic()
for index in range(19):
    target = start + index * 10
    time.sleep(max(0, target - time.monotonic()))
    snapshot = json.loads(d.shell('curl -fsS --max-time 5 --unix-socket /run/airsim-v2/control.sock http://localhost/v2/local/snapshot'))
    ready = json.loads(d.shell('curl -fsS --max-time 5 --unix-socket /run/airsim-v2/control.sock http://localhost/readyz'))
    status = d.shell('cat /proc/' + pid + '/status')
    metrics = {key: int(re.search(r'^' + key + r':\s+(\d+)', status, re.M).group(1)) for key in ('VmRSS', 'VmHWM', 'Threads')}
    metrics['FD'] = int(d.shell('ls /proc/' + pid + '/fd | wc -l'))
    record = {'elapsed_seconds': round(time.monotonic() - start, 3), 'revision': snapshot['revision'], 'module_id': snapshot['module_id'], 'agent_boot_id': snapshot['agent_boot_id'], 'freshness': snapshot['freshness'], 'ready': ready, 'resources': metrics, 'fields': {k: snapshot['fields'][k] for k in ('sim', 'signal', 'registration', 'ims', 'calls', 'platform')}}
    records.append(record)
    pathlib.Path(output).write_text(json.dumps({**metadata, "samples": records}, indent=2) + '\n')
    if index % 3 == 0:
        print(json.dumps({k: record[k] for k in ('elapsed_seconds', 'revision', 'freshness', 'resources')}), flush=True)
    if not ready['ready'] or snapshot['freshness'] != 'fresh':
        raise RuntimeError('read-only readiness lost')
