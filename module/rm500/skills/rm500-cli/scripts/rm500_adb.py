#!/usr/bin/env python3
"""Run one finite RM500 JSON command, checking the device's actual exit status."""

import argparse
import json
import math
import os
import re
import secrets
import shlex
import subprocess
import sys


def wrapper_error(code, message):
    print(json.dumps({"ok": False, "error": {
        "code": code, "source": "adb-wrapper", "message": message,
    }}, ensure_ascii=False), file=sys.stderr)
    return code


def has_flag(args, name):
    return any(arg == name or arg.startswith(name + "=") for arg in args)


def parse_result(output, marker):
    # Old adb shell merges remote stderr and may translate LF to CRLF.
    output = output.decode("utf-8").replace("\r\n", "\n")
    tail = re.search(r"\n" + re.escape(marker) + r"([0-9]{1,3})\n?\Z", output)
    if tail is None:
        raise ValueError("Missing device exit marker; execution outcome is unknown.")
    code = int(tail.group(1))
    if code > 255:
        raise ValueError("Invalid device exit status.")
    payload = json.loads(output[:tail.start()].strip())
    if not isinstance(payload, dict) or type(payload.get("ok")) is not bool:
        raise ValueError("Device did not return a single RM500 JSON response.")
    if payload["ok"] != (code == 0):
        raise ValueError("Device exit status disagrees with the JSON response.")
    return code, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Explicit target from adb devices -l")
    parser.add_argument("--adb", default=os.environ.get("ADB", "adb"))
    parser.add_argument("--binary", default="/mnt/data/airsim/bin/rm500")
    parser.add_argument("--at-device", default="/dev/smd1")
    parser.add_argument("--host-timeout", type=float, default=90,
                        help="ADB wait limit in seconds; does not cancel remote work reliably")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="-- followed by a finite rm500 command and its flags")
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or command[0].startswith("-"):
        return wrapper_error(2, "Supply -- followed by the command name, then CLI flags.")
    if command[0] in {"stream", "watch", "repl"}:
        return wrapper_error(2, "Run streams, watch and REPL on the module; this helper accepts one JSON response.")
    if any(arg.startswith("--json=") and arg != "--json=true" for arg in command):
        return wrapper_error(2, "This helper requires JSON output.")
    if "@-" in command or "--data=@-" in command:
        return wrapper_error(2, "This helper does not forward stdin; use a device-side file or shell.")
    if not args.serial or not args.adb or not args.binary.startswith("/") or not args.at_device.startswith("/"):
        return wrapper_error(2, "Provide a serial, an adb executable, and absolute device paths.")
    if not math.isfinite(args.host_timeout) or args.host_timeout <= 0:
        return wrapper_error(2, "--host-timeout must be a finite positive number.")
    if not has_flag(command, "--json"):
        command += ["--json"]
    if not has_flag(command, "--at-device"):
        command += ["--at-device", args.at_device]

    marker = "__RM500_EXIT_" + secrets.token_hex(16) + "__"
    # argv is quoted for the remote shell, not JSON-escaped or interpolated raw.
    remote = (shlex.join([args.binary, *command]) + " 2>&1; rm500_rc=$?; "
              + "printf '\\n" + marker + "%s\\n' \"$rm500_rc\"")
    try:
        result = subprocess.run([args.adb, "-s", args.serial, "shell", remote],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=args.host_timeout,
                                check=False)
    except subprocess.TimeoutExpired:
        return wrapper_error(4, "ADB wait timed out. Remote execution may continue; inspect device state before retrying.")
    except KeyboardInterrupt:
        return wrapper_error(130, "Interrupted. Remote execution may continue; inspect device state before retrying.")
    except (OSError, ValueError):
        return wrapper_error(3, "Could not run adb; check the executable, arguments and connection.")
    if result.returncode != 0:
        return wrapper_error(3, "ADB transport failed; device execution outcome is unknown.")
    try:
        code, payload = parse_result(result.stdout, marker)
    except (ValueError, UnicodeError):
        return wrapper_error(3, "Missing/invalid device JSON or exit marker; execution outcome is unverified.")
    # No files, command echo, retries, or unverified partial-output logging.
    print(json.dumps(payload, ensure_ascii=False), file=sys.stdout if code == 0 else sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
