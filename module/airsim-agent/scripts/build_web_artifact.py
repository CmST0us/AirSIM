#!/usr/bin/env python3
"""Build the Linux/arm64 Agent artifacts served by the pairing page."""

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


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def version() -> str:
    text = (ROOT / "cmd" / "airsim-agent" / "main.go").read_text()
    match = re.search(r'const version = "([^"]+)"', text)
    if not match:
        raise SystemExit("Agent version not found")
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--go", default=os.environ.get("GO", "go"))
    args = parser.parse_args()

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="airsim-agent-web-") as temporary:
        binary = pathlib.Path(temporary) / "airsim-agent"
        environment = os.environ.copy()
        environment.update({
            "CGO_ENABLED": "0",
            "GOOS": "linux",
            "GOARCH": "arm64",
            "GOTOOLCHAIN": "local",
        })
        subprocess.run(
            [args.go, "build", "-trimpath", "-ldflags=-s -w", "-o", str(binary), "./cmd/airsim-agent"],
            cwd=ROOT,
            env=environment,
            check=True,
        )
        shutil.copyfile(binary, output / "airsim-agent")
    shutil.copyfile(ROOT / "deploy" / "rm500u" / "run-agent.sh", output / "run-agent.sh")
    shutil.copyfile(ROOT.parent / "rm500" / "audio" / "dist" / "airsim-audiod", output / "airsim-audiod")

    agent = output / "airsim-agent"
    launcher = output / "run-agent.sh"
    audio = output / "airsim-audiod"
    manifest = {
        "schema_version": 1,
        "version": version(),
        "os": "linux",
        "arch": "arm64",
        "agent": {
            "path": "airsim-agent",
            "size": agent.stat().st_size,
            "sha256": digest(agent),
        },
        "launcher": {
            "path": "run-agent.sh",
            "size": launcher.stat().st_size,
            "sha256": digest(launcher),
        },
        "audio": {
            "path": "airsim-audiod",
            "size": audio.stat().st_size,
            "sha256": digest(audio),
        },
    }
    temporary = output / ".manifest.json.new"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(output / "manifest.json")
    print(f"built AirSIM Engine {manifest['version']} ({agent.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
