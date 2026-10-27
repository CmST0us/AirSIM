#!/bin/sh
set -eu
umask 077

base=/mnt/data/airsim-v2
runtime=/run/airsim-v2
agent="$base/current/airsim-agent"
audio_helper="$base/audio-current/airsim-audiod"

mkdir -p "$runtime"
chmod 700 "$runtime"

# The firmware exposes the AT node before its kernel random source is ready.
while [ ! -c /dev/smd1 ]; do
    sleep 2
done
[ -x "$agent" ] || exit 1

# This blocking probe returns only after the kernel random source is initialized.
# It prevents an Agent process from sitting without a control socket on first boot.
"$agent" --wait-random </dev/null >>"$runtime/agent.log" 2>&1

exec "$agent" \
    --profile rm500u-embedded \
    --at-device /dev/smd1 \
    --audio-helper "$audio_helper" \
    </dev/null >>"$runtime/agent.log" 2>&1
