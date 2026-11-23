#!/bin/sh
# Unified Rust Engine shim for existing web installer / run-agent.sh compatibility.
# Audio now runs in-process inside airsim-agent (zero Unix sockets, SCHED_FIFO).
# Supports --version and --cleanup --profile <profile> directly via the unified binary.
self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -x "$self_dir/../current/airsim-agent" ]; then
  exec "$self_dir/../current/airsim-agent" --audio-helper-shim "$@"
fi
if [ -x /usrdata/airsim-v2/current/airsim-agent ]; then
  exec /usrdata/airsim-v2/current/airsim-agent --audio-helper-shim "$@"
fi
if [ -x /mnt/data/airsim-v2/current/airsim-agent ]; then
  exec /mnt/data/airsim-v2/current/airsim-agent --audio-helper-shim "$@"
fi
echo "airsim-audiod: unified engine binary not found" >&2
exit 1
