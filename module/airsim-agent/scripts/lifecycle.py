"""Authorized R1 lifecycle checks; signals only a verified executable/PID."""
import json
import pathlib
import shlex
import sys
import time
from adb_device import Device

serial, state_file, output_file = sys.argv[1:]
run = json.loads(pathlib.Path(state_file).read_text())
d = Device(serial)
exe = run['remote']

def get(path):
    return json.loads(d.shell('curl -fsS --max-time 5 --unix-socket /run/airsim-v2/control.sock http://localhost' + path))

def verify(pid):
    if d.shell('readlink /proc/' + str(pid) + '/exe') != exe:
        raise RuntimeError('refusing to signal a different process')

def stopped(pid):
    end = time.monotonic() + 10
    while time.monotonic() < end:
        if d.shell('if test -d /proc/' + str(pid) + '; then printf present; else printf absent; fi') == 'absent':
            return
        time.sleep(.1)
    raise RuntimeError('process did not exit within budget')

def start():
    pid = int(d.shell('nohup setsid ' + shlex.quote(exe) + ' --profile rm500u-embedded --at-device /dev/smd1 </dev/null >/run/airsim-v2/agent.log 2>&1 &\npid=$!\nsleep 1\nkill -0 "$pid" || exit 1\nprintf "%s" "$pid"'))
    verify(pid)
    run['pid'] = pid
    pathlib.Path(state_file).write_text(json.dumps(run))
    for _ in range(10):
        try:
            ready = get('/readyz')
            if ready['ready']:
                return pid, get('/v2/local/snapshot')
        except RuntimeError:
            pass
        time.sleep(.2)
    raise RuntimeError('restart not ready')

before = get('/v2/local/snapshot')
verify(run['pid'])
evidence = {'binary': exe, 'sha256': run['sha256'], 'before': {'pid': run['pid'], 'module_id': before['module_id'], 'agent_boot_id': before['agent_boot_id']}}
for suffix in ('', ' --runtime-dir /run/airsim-v2-second'):
    response = d.shell(shlex.quote(exe) + ' --profile rm500u-embedded --at-device /dev/smd1' + suffix, expected=1)
    if response != 'airsim-agent: lock_conflict':
        raise RuntimeError('duplicate did not fail at instance lock')
evidence['duplicate_instances_rejected'] = True
assert get('/readyz')['ready']
start_time = time.monotonic()
d.shell('kill -TERM ' + str(run['pid']))
stopped(run['pid'])
d.shell('test ! -e /run/airsim-v2/control.sock && test ! -e /run/airsim-v2/at-inflight.json')
evidence['sigterm_exit_seconds'] = round(time.monotonic() - start_time, 3)
pid, after = start()
assert before['module_id'] == after['module_id'] and before['agent_boot_id'] != after['agent_boot_id']
evidence['after_sigterm_restart'] = {'pid': pid, 'module_id': after['module_id'], 'agent_boot_id': after['agent_boot_id']}
# Observe a newly completed sample; the next polling tick is approximately ten seconds away.
previous = after['revision']
end = time.monotonic() + 15
while time.monotonic() < end:
    current = get('/v2/local/snapshot')
    if current['revision'] > previous and current['freshness'] == 'fresh':
        break
    time.sleep(.1)
else:
    raise RuntimeError('no safe observed polling gap')
verify(pid)
d.shell('test ! -e /run/airsim-v2/at-inflight.json && kill -KILL ' + str(pid))
stopped(pid)
d.shell('test ! -e /run/airsim-v2/at-inflight.json')
evidence['sigkill_at_idle_revision'] = current['revision']
final_pid, final = start()
assert final['module_id'] == before['module_id'] and final['agent_boot_id'] != after['agent_boot_id']
evidence['after_sigkill_restart'] = {'pid': final_pid, 'module_id': final['module_id'], 'agent_boot_id': final['agent_boot_id']}
evidence['health'] = get('/healthz')
evidence['ready'] = get('/readyz')
evidence['capabilities'] = get('/v2/local/capabilities')
evidence['snapshot'] = final
pathlib.Path(output_file).write_text(json.dumps(evidence, indent=2) + '\n')
print(json.dumps({k: v for k, v in evidence.items() if k not in ('capabilities', 'snapshot')}), flush=True)
