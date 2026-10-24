"""Read-only R2 evidence. Never fetch business calls/messages or print payloads."""
import json
import pathlib
import re
import sys
import time
from adb_device import Device

run_file, output = sys.argv[1:]
run = json.loads(pathlib.Path(run_file).read_text())
d = Device('0123456789ABCDEF')
pid = str(run['pid'])
assert pid.isdigit()
assert d.shell('readlink /proc/' + pid + '/exe') == run['remote']
assert d.shell('sha256sum ' + run['remote']).split()[0] == run['sha256']
def get(path):
    return json.loads(d.shell('curl -fsS --max-time 5 --unix-socket /run/airsim-v2/control.sock http://localhost/' + path))
health = get('healthz')
assert health['version'] == '2.0.0-dev.r2'
assert health['agent_boot_id'] != run['previous_boot']
evidence = {**run, 'version': health['version'], 'agent_boot_id': health['agent_boot_id'], 'samples': []}
start = time.monotonic()
for i in range(19):
    time.sleep(max(0, start + i * 10 - time.monotonic()))
    snapshot = get('v2/local/snapshot')
    readonly = get('readyz')
    control = get('v2/local/control')
    assert control['backend_epoch'] != run['previous_epoch']
    status = d.shell('cat /proc/' + pid + '/status')
    resources = {k: int(re.search(r'^' + k + r':\s+(\d+)', status, re.M).group(1)) for k in ('VmRSS', 'VmHWM', 'Threads')}
    resources['FD'] = int(d.shell('ls /proc/' + pid + '/fd | wc -l'))
    sample = {'elapsed_seconds': round(time.monotonic() - start, 3), 'revision': snapshot['revision'], 'module_id': snapshot['module_id'], 'freshness': snapshot['freshness'], 'readonly': readonly, 'control': control, 'resources': resources}
    evidence['samples'].append(sample)
    pathlib.Path(output).write_text(json.dumps(evidence, indent=2) + '\n')
    if i % 3 == 0:
        print(json.dumps({'elapsed_seconds': sample['elapsed_seconds'], 'revision': sample['revision'], 'control_ready': control['ready'], 'resources': resources}), flush=True)
    assert readonly['ready'] and control['ready'] and snapshot['freshness'] == 'fresh'
    assert not control['voice_ready'] and not control['inbox_gap'] and control['inbox_dropped'] == 0
    assert control['command_capacity_remaining'] == 1024
    assert control['backend_epoch'] == evidence['samples'][0]['control']['backend_epoch']
evidence['capabilities'] = get('v2/local/capabilities')
evidence['permissions'] = d.shell("stat -c '%a %n' /mnt/data/airsim-v2 /mnt/data/airsim-v2/state /mnt/data/airsim-v2/config/identity.json /run/airsim-v2 /run/airsim-v2/control.sock").splitlines()
evidence['log_bytes'] = int(d.shell('wc -c </run/airsim-v2/agent-r2.log'))
evidence['r1_release_unchanged'] = d.shell('sha256sum ' + run['r1_release']).split()[0] == 'b9659d09758375ba8597654339d7b76f63603c7588134b478e7a9b3481569707'
evidence['free_space'] = d.shell('df -k /mnt/data').splitlines()[-1]
evidence['command_journal_absent_before_business'] = d.shell('if test -e /mnt/data/airsim-v2/state/commands.json; then printf present; else printf absent; fi') == 'absent'
pathlib.Path(output).write_text(json.dumps(evidence, indent=2) + '\n')
print(json.dumps({'complete': True, 'pid': run['pid'], 'boot': health['agent_boot_id'], 'epoch': evidence['samples'][-1]['control']['backend_epoch']}), flush=True)
