#!/usr/bin/env python3
"""Install the RM500U Agent launcher and enable BusyBox-init respawn."""

import argparse
import pathlib
import shlex
import subprocess
import sys

from adb_device import Device


ROOT = pathlib.Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "deploy" / "rm500u" / "run-agent.sh"
BASE = "/mnt/data/airsim-v2"
INITTAB_ENTRY = f"asm:12345:respawn:{BASE}/run-agent.sh"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial", required=True)
    parser.add_argument("--binary", type=pathlib.Path, default=ROOT / "dist" / "airsim-agent")
    args = parser.parse_args()

    if not args.binary.is_file():
        raise SystemExit(f"binary not found: {args.binary}")
    if not LAUNCHER.is_file():
        raise SystemExit(f"launcher not found: {LAUNCHER}")

    device = Device(args.serial)
    release, digest = device.deploy(args.binary)
    release_name = pathlib.Path(release).parent.name
    release_link = f"releases/{release_name}"
    current_link = f"{BASE}/current"

    remote_launcher = f"{BASE}/.run-agent.sh.new"
    subprocess.run(
        device.args + ["push", str(LAUNCHER), remote_launcher],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    device.shell(
        "\n".join(
            [
                "set -eu",
                f"mkdir -p {shlex.quote(BASE + '/config')} {shlex.quote(BASE + '/state')}",
                f"chmod 700 {shlex.quote(BASE + '/config')} {shlex.quote(BASE + '/state')}",
                f"if [ ! -f {shlex.quote(BASE + '/config/random.seed')} ]; then "
                f"dd if=/dev/urandom of={shlex.quote(BASE + '/config/random.seed.tmp')} bs=64 count=1 2>/dev/null; "
                f"chmod 600 {shlex.quote(BASE + '/config/random.seed.tmp')}; "
                f"mv -f {shlex.quote(BASE + '/config/random.seed.tmp')} {shlex.quote(BASE + '/config/random.seed')}; "
                "fi",
                f"test \"$(wc -c <{shlex.quote(BASE + '/config/random.seed')})\" -eq 64",
                f"chmod 700 {shlex.quote(remote_launcher)}",
                f"mv -f {shlex.quote(remote_launcher)} {shlex.quote(BASE + '/run-agent.sh')}",
                f"previous=\"$(readlink {shlex.quote(current_link)} 2>/dev/null || true)\"",
                f"rm -f {shlex.quote(BASE + '/current.next')} {shlex.quote(current_link)}",
                "ln -s " + shlex.quote(release_link) + " " + shlex.quote(BASE + "/current.next"),
                "mv " + shlex.quote(BASE + "/current.next") + " " + shlex.quote(current_link),
                "test \"$(readlink "
                + shlex.quote(current_link)
                + ")\" = "
                + shlex.quote(release_link),
                f"for d in {shlex.quote(BASE + '/releases')}/*; do "
                "[ -d \"$d\" ] || continue; "
                "name=${d##*/}; link=releases/$name; "
                f"if [ \"$link\" = \"$previous\" ] || [ \"$name\" = {shlex.quote(release_name)} ]; then continue; fi; "
                "rm -f \"$d/airsim-agent\" || true; "
                "rmdir \"$d\" 2>/dev/null || true; "
                "done",
            ]
        )
    )

    config = f"""set -eu
base={shlex.quote(BASE)}
backup="$base/config/inittab.orig"
tmp="$base/config/inittab.new"
mkdir -p "$base/config"
chmod 700 "$base/config"
mount -o remount,rw /
restore_ro() {{
    sync
    mount -o remount,ro / || true
}}
trap restore_ro EXIT HUP INT TERM
if [ ! -f "$backup" ]; then
    cp /etc/inittab "$backup"
    chmod 600 "$backup"
fi
grep -v '^asm:' /etc/inittab >"$tmp" || true
printf '%s\\n' {shlex.quote(INITTAB_ENTRY)} >>"$tmp"
cat "$tmp" >/etc/inittab
chmod 644 /etc/inittab
rm -f "$tmp"
test "$(grep -c '^asm:' /etc/inittab)" -eq 1
sync
mount -o remount,ro /
trap - EXIT HUP INT TERM
"""
    device.shell(config, timeout=60)

    print(f"installed {digest[:16]} with BusyBox-init respawn; reboot required")
    return 0


if __name__ == "__main__":
    sys.exit(main())
