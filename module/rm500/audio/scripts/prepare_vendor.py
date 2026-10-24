"""Apply one exact upstream backport to a verified build copy, never vendor."""
import difflib
import hashlib
import json
import pathlib
import runpy

root = pathlib.Path(__file__).resolve().parent.parent
runpy.run_path(str(root / 'scripts/verify_vendor.py'))
meta = json.loads((root / 'patches/SOURCE.json').read_text())
source = (root / 'vendor/tinyalsa/src/pcm.c').read_bytes()
patch = (root / 'patches/pcm-state-sync-ptr.patch').read_bytes()
assert hashlib.sha256(source).hexdigest() == meta['source_sha256']
assert hashlib.sha256(patch).hexdigest() == meta['patch_sha256']
old = b'int pcm_state(struct pcm *pcm)\n{\n    int err = pcm_sync_ptr(pcm, 0);'
new = old.replace(b'pcm, 0', b'pcm, SNDRV_PCM_SYNC_PTR_APPL | SNDRV_PCM_SYNC_PTR_AVAIL_MIN')
assert source.count(old) == 1
result = source.replace(old, new)
expected_patch = ''.join(difflib.unified_diff(source.decode().splitlines(True), result.decode().splitlines(True), fromfile='a/src/pcm.c', tofile='b/src/pcm.c')).encode()
assert patch == expected_patch, 'patch must be exactly the single frozen change'
assert hashlib.sha256(result).hexdigest() == meta['result_sha256']
out = root / 'dist/tinyalsa/pcm.c'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(result)
print('Exact pcm_state backport verified:', meta['result_sha256'])
