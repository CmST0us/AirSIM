#!/usr/bin/env python3
"""Build platform-specific Agent artifacts for the pairing page."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
PROFILES = {"rm500u-embedded": ("arm64", "rm500u", "rm500"), "eg25-qdc507": ("arm", "eg25", "eg25")}


def artifact(path):
    return {"path": path.name, "size": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--go", default=os.environ.get("GO", "go"))
    parser.add_argument("--profile", choices=PROFILES, action="append")
    args = parser.parse_args()
    version = re.search(r'const version = "([^"]+)"', (ROOT / "cmd/airsim-agent/main.go").read_text()).group(1)
    for profile in args.profile or PROFILES:
        arch, deployment, platform = PROFILES[profile]
        output = args.output.resolve() / profile
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="airsim-agent-web-") as temporary:
            binary = pathlib.Path(temporary) / "airsim-agent"
            env = dict(os.environ, CGO_ENABLED="0", GOOS="linux", GOARCH=arch, GOARM="7", GOTOOLCHAIN="go1.24.13")
            subprocess.run([args.go, "build", "-trimpath", "-ldflags=-s -w", "-o", str(binary), "./cmd/airsim-agent"], cwd=ROOT, env=env, check=True)
            shutil.copyfile(binary, output / binary.name)
        shutil.copyfile(ROOT / "deploy" / deployment / "run-agent.sh", output / "run-agent.sh")
        shutil.copyfile(ROOT.parent / platform / "audio/dist/airsim-audiod", output / "airsim-audiod")
        manifest = {"schema_version": 1, "version": version, "os": "linux", "arch": arch, "profile": profile}
        for key, name in (("agent", "airsim-agent"), ("launcher", "run-agent.sh"), ("audio", "airsim-audiod")):
            manifest[key] = artifact(output / name)
        manifest["licenses"] = []
        for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
            shutil.copyfile(REPO / name, output / name)
            manifest["licenses"].append(artifact(output / name))
        if platform == "eg25":
            manifest["platform"] = []
            for name in ("airsim_data11.ko", "qdc507_aprv3.ko", "qdc507_voice.ko", "COPYING-GPL-2.0", "MODULE-REPORT.md", "airsim_data11.c", "isrgrootx1.pem"):
                source = ROOT.parent / "eg25/dist" / name
                if not source.exists():
                    raise SystemExit("Prepare the EG25 runtime first; see module/eg25/README.md: " + str(source))
                shutil.copyfile(source, output / name)
                manifest["platform"].append(artifact(output / name))
        temporary = output / ".manifest.json.new"
        temporary.write_text(json.dumps(manifest, indent=2) + "\n")
        temporary.replace(output / "manifest.json")
        print(f"built AirSIM Engine {version}: {profile}, {manifest['agent']['size']} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
