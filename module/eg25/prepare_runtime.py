#!/usr/bin/env python3
"""Stage the QDC507 runtime and its GPL notices for the web installer."""
import argparse
import pathlib
import shutil
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
REVISION = '0443dfdaf8aec086fd76ba2ee9152fd908114524'
parser = argparse.ArgumentParser()
parser.add_argument('--data11-ko', type=pathlib.Path, default=ROOT/'kmod/airsim_data11.ko')
args = parser.parse_args()
if not args.data11_ko.exists():
    raise SystemExit('Build kmod/airsim_data11.ko against the QDC507 kernel first.')
dest = ROOT/'dist'
dest.mkdir(exist_ok=True)
shutil.copyfile(args.data11_ko, dest/'airsim_data11.ko')
for name in ('qdc507_aprv3.ko', 'qdc507_voice.ko', 'COPYING-GPL-2.0', 'MODULE-REPORT.md'):
    with urllib.request.urlopen(f'https://raw.githubusercontent.com/moluncn/mavo/{REVISION}/Resources/ModuleVoice/{name}', timeout=60) as response:
        (dest/name).write_bytes(response.read())
shutil.copyfile(ROOT/'kmod/airsim_data11.c', dest/'airsim_data11.c')
shutil.copyfile(ROOT/'certs/isrgrootx1.pem', dest/'isrgrootx1.pem')
print('QDC507 runtime and GPL notices prepared')
