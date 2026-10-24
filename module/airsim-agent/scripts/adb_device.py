"""R1 deployment helper. Every shell operation checks an explicit device exit marker."""
import hashlib
import pathlib
import re
import shlex
import subprocess
import uuid

class Device:
    def __init__(self, serial):
        listing = subprocess.check_output(['adb', 'devices', '-l'], text=True)
        matches = [line for line in listing.splitlines() if line.split()[:2] == [serial, 'device']]
        if len(matches) != 1:
            raise RuntimeError('expected exactly one selected authorized device')
        match = re.search(r'\btransport_id:(\d+)\b', matches[0])
        if not match:
            raise RuntimeError('missing current transport ID')
        self.args = ['adb', '-t', match.group(1)]
        self.transport = match.group(1)
        if self.shell('uname -s; uname -m; uname -n').splitlines() != ['Linux', 'aarch64', 'udx710-module']:
            raise RuntimeError('target platform mismatch')

    def shell(self, command, expected=0, timeout=20):
        marker = '__AIRSIM_RC_' + uuid.uuid4().hex + '__'
        script = '(\n' + command + '\n)\nrc=$?\nprintf "\\n' + marker + '%s\\n" "$rc"'
        result = subprocess.run(self.args + ['shell', script], capture_output=True, text=True, timeout=timeout, check=True)
        output = result.stdout.replace('\r', '')
        match = re.search(r'\n' + marker + r'(\d+)\n?$', output)
        if not match:
            raise RuntimeError('missing device exit status')
        self.last_status = int(match.group(1))
        accepted = expected if isinstance(expected, tuple) else (expected,)
        if self.last_status not in accepted:
            raise RuntimeError('device operation failed, status=' + match.group(1))
        return output[:match.start()].strip()

    def deploy(self, binary, name="airsim-agent"):
        if name not in {"airsim-agent", "at-probe"}:
            raise ValueError("invalid R1 binary name")
        binary = pathlib.Path(binary)
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        directory = '/mnt/data/airsim-v2/releases/' + digest[:16]
        self.shell('umask 077\nmkdir -p ' + directory + '\nchmod 700 /mnt/data/airsim-v2 /mnt/data/airsim-v2/releases ' + directory)
        remote = directory + '/' + name
        # Avoid overwriting an executable currently mapped by a process.
        exists = self.shell('if test -e ' + remote + '; then printf yes; else printf no; fi')
        if exists == 'no':
            subprocess.run(self.args + ['push', str(binary), remote], check=True, capture_output=True)
        actual = self.shell('sha256sum ' + remote).split()[0]
        if actual != digest:
            raise RuntimeError('target digest mismatch')
        self.shell('chmod 700 ' + remote)
        return remote, digest
