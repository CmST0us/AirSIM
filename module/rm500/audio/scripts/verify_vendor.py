import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parent.parent/'vendor/tinyalsa'
manifest=json.loads((root/'SOURCE.json').read_text())
assert manifest['commit']=='1c5fb68ced57d838f2b7ecd0c00bc1fefc9ab60d'
for name,digest in manifest['files'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
print('TinyALSA pinned source hashes verified')
