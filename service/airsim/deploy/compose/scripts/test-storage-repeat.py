#!/usr/bin/env python3
"""Real-volume regression test. No production volumes or cloud connections."""
import hashlib,json,os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[3]
compose=os.environ.get('AIRSIM_COMPOSE_BIN','/tmp/airsim-r4-compose-2.26.1')
env=dict(os.environ,AIRSIM_PROJECT='airsim-r4-test',AIRSIM_SECRET_DIR='/tmp/airsim-r4-test-unused',AIRSIM_API_ORIGIN='https://api.example.invalid',AIRSIM_DEVICE_ORIGIN='https://device.example.invalid',AIRSIM_MEDIA_ORIGIN='https://api.example.invalid',AIRSIM_API_HOST='api.example.invalid',AIRSIM_BUSINESS_IMAGE='sha256:'+'0'*64)
base=[compose,'-p','airsim-r4-test','-f',str(root/'deploy/compose/compose.production.yaml'),'-f',str(root/'deploy/compose/storage-repeat-test.override.yaml')]
def run(args):
    return subprocess.run(base+['run','-T','--interactive=false','--rm','--no-deps']+args,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,check=True).stdout.strip()
def nonroot(script):
    return run(['--user','65532:65532','--entrypoint','/bin/sh','edge-storage-init','-ec',script])
run(['edge-storage-init'])
nonroot('umask 077; for dir in /data /config; do if test -e "$dir/r4-init-sentinel"; then test "$(cat "$dir/r4-init-sentinel")" = "airsim-r4-repeat-init-fixture"; else printf "%s\\n" "airsim-r4-repeat-init-fixture" > "$dir/r4-init-sentinel"; fi; done')
check='for dir in /data /config; do test "$(stat -c %u:%g:%a "$dir")" = 65532:65532:700; test "$(stat -c %u:%g:%a "$dir/r4-init-sentinel")" = 65532:65532:600; sha256sum "$dir/r4-init-sentinel"; stat -c %u:%g:%a:%s:%Y:%Z "$dir/r4-init-sentinel"; done'
before=nonroot(check)
run(['edge-storage-init'])
after=nonroot(check)
if before!=after:raise SystemExit('repeat_initialization_modified_contents_or_metadata')
record={'date':'2026-10-24','project':'airsim-r4-test','compose_version':subprocess.check_output([compose,'version','--short'],text=True).strip(),'initialization_runs':2,'production_compose_sha256':hashlib.sha256((root/'deploy/compose/compose.production.yaml').read_bytes()).hexdigest(),'second_run_existing_files':True,'directories':'65532:65532:0700','files':'65532:65532:0600','content_and_file_metadata_unchanged':True,'comparison_sha256':hashlib.sha256(before.encode()).hexdigest(),'stdin':'DEVNULL; run -T --interactive=false','cloud_or_device_operations':False,'volumes':['airsim-r4-test-repeat-tls','airsim-r4-test-repeat-config']}
(root/'R4_STORAGE_REPEAT_EVIDENCE.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record))
