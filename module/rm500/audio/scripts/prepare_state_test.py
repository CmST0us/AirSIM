"""Test the exact two source functions with a host fake SYNC_PTR ioctl.
No device headers or ABI are emulated: only pointer exchange semantics.
"""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
for variant, path in [('patched', 'dist/tinyalsa/pcm.c'), ('original', 'vendor/tinyalsa/src/pcm.c')]:
    source = (root / path).read_text()
    functions = []
    for signature in ['static int pcm_sync_ptr(struct pcm *pcm, int flags)', 'int pcm_state(struct pcm *pcm)']:
        assert source.count(signature + '\n{') == 1
        start = source.index(signature + '\n{')
        end = source.index('\n}\n', start) + 3
        functions.append(source[start:end])
    out = root / 'dist' / ('state-' + variant) / 'state-functions.inc'
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text('\n'.join(functions))
