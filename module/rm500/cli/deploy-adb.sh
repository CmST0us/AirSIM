#!/bin/sh
# Install the ARM64 CLI on the explicitly selected RM500U; no rootfs/service changes.
set -eu
cd "$(dirname "$0")"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo 'Usage: ./deploy-adb.sh ADB_SERIAL [ARM64_BINARY]' >&2
  exit 2
fi
serial=$1
binary=${2:-dist/rm500-linux-arm64}
adb_bin=${ADB:-adb}
dest=/mnt/data/airsim/bin/rm500
staged=$dest.new.$$
test -f "$binary"

# This firmware's old ADB protocol does not propagate the remote exit code.
# A distinct final marker is mandatory for every checked remote operation.
remote() {
  result=$("$adb_bin" -s "$serial" shell "$1; rm500_rc=\$?; printf '\\n__RM500_EXIT__%s\\n' \"\$rm500_rc\"" | tr -d '\r')
  code=$(printf '%s\n' "$result" | tail -n 1)
  if [ "$code" != '__RM500_EXIT__0' ]; then
    printf '%s\n' "$result" >&2
    return 1
  fi
  printf '%s\n' "$result" | sed '$d'
}
remote 'test "$(uname -m)" = aarch64' >/dev/null
remote 'test -d /mnt/data && mkdir -p /mnt/data/airsim/bin' >/dev/null
trap '"$adb_bin" -s "$serial" shell "rm -f $staged" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' HUP INT TERM
"$adb_bin" -s "$serial" push "$binary" "$staged"
if command -v sha256sum >/dev/null 2>&1; then
  expected=$(sha256sum "$binary" | awk '{print $1}')
else
  expected=$(shasum -a 256 "$binary" | awk '{print $1}')
fi
actual=$(remote "sha256sum $staged" | awk 'NR==1 {print $1}')
if [ "$expected" != "$actual" ]; then
  echo 'SHA-256 mismatch; installed binary has not been replaced.' >&2
  exit 1
fi
# Preserve one previous CLI, then rename on the same filesystem atomically.
remote "chmod 755 $staged && (test ! -f $dest || cp -p $dest $dest.previous) && mv $staged $dest" >/dev/null
remote "$dest version --json"
printf 'Installed %s; SHA-256 %s\n' "$dest" "$actual"
