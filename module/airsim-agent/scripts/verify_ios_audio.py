#!/usr/bin/env python3
"""Offline production iOS/Go interoperability with synthetic in-memory audio.

Requires an already booted iOS simulator and an existing Xcode derived-data
build containing WebRTC.framework. Never uses a microphone or cloud service;
prints only fixed stages and counts, not SDP, addresses or audio.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data', type=Path, required=True)
parser.add_argument('--simulator', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
module = root / 'module/airsim-agent'
fixture = Path(__file__).resolve().parent / 'ios_audio_probe'
frameworks = args.derived_data.resolve() / 'Build/Products/Debug-iphonesimulator'
if not (frameworks / 'WebRTC.framework').exists():
    parser.error('WebRTC.framework missing from derived data')
server = None
with tempfile.TemporaryDirectory(prefix='airsim-audio-ios-') as staging, tempfile.TemporaryDirectory(prefix='probe-audio-', dir=module) as go_dir:
    stage = Path(staging)
    try:
        shutil.copy(fixture / 'main.go', Path(go_dir) / 'main.go')
        subprocess.run(['go', 'build', '-o', str(stage / 'server'), '.'], cwd=go_dir, check=True)
        server = subprocess.Popen([str(stage / 'server')], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        address = server.stdout.readline().strip()
        if not address.startswith('127.0.0.1:'):
            raise RuntimeError('loopback server unavailable')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-sdk', sdk,
                        '-target', 'arm64-apple-ios18.0-simulator', '-F', str(frameworks), '-framework', 'WebRTC',
                        '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                        str(root / 'iOS/AirSIM/CloudV2/V2JSON.swift'), str(root / 'iOS/AirSIM/CloudV2/V2WebRTC.swift'),
                        str(fixture / 'SyntheticAudioDevice.swift'), str(fixture / 'Probe.swift'),
                        '-o', str(stage / 'probe')], check=True)
        result = subprocess.run(['xcrun', 'simctl', 'spawn', args.simulator, str(stage / 'probe'), 'http://' + address],
                                capture_output=True, text=True, timeout=45)
        for line in result.stdout.splitlines():
            if line.startswith('PROBE'):
                print(line)
        if result.returncode:
            print('PROBE simulator exit:', result.returncode)
        raise SystemExit(result.returncode)
    finally:
        if server:
            server.terminate()
            server.wait(timeout=5)
