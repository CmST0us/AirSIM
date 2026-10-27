#!/bin/sh
set -eu
umask 077

base=/mnt/data/airsim-v2
runtime=/run/airsim-v2
state="$base/state"
agent="$base/current/airsim-agent"
audio_helper="$base/audio-current/airsim-audiod"
random_seed="$base/config/random.seed"

mkdir -p "$runtime"
chmod 700 "$runtime"
mkdir -p "$state"
chmod 700 "$state"

printf '%s boot_id=%s boot_reason=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)" \
    "$(sed -n 's/.*boot_reason=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)" \
    >>"$state/boot.log"
if [ "$(wc -l <"$state/boot.log")" -gt 200 ]; then
    tail -n 200 "$state/boot.log" >"$state/boot.log.next"
    mv -f "$state/boot.log.next" "$state/boot.log"
fi

# The firmware exposes the AT node before its kernel random source is ready.
while [ ! -c /dev/smd1 ]; do
    sleep 2
done
[ -x "$agent" ] || exit 1

network_wait=0
while [ ! -d /sys/class/net/sipa_eth0 ] && [ "$network_wait" -lt 30 ]; do
    sleep 1
    network_wait=$((network_wait + 1))
done
if [ -d /sys/class/net/sipa_eth0 ]; then
    ip link set dev sipa_eth0 mtu 1400
fi

# Seed this boot's CRNG from a byte-for-byte persistent secret, then replace the
# seed for the next boot. Without this, the firmware takes roughly two minutes
# to initialize its random source and the Agent cannot create its identity or
# cloud transport during that window.
if [ -f "$random_seed" ] && [ "$(wc -c <"$random_seed")" -eq 64 ]; then
    dd if="$random_seed" of=/dev/urandom bs=64 count=1 2>/dev/null
    dd if=/dev/urandom of="$random_seed.next" bs=64 count=1 2>/dev/null
    chmod 600 "$random_seed.next"
    mv -f "$random_seed.next" "$random_seed"
fi

exec "$agent" \
    --profile rm500u-embedded \
    --at-device /dev/smd1 \
    --audio-helper "$audio_helper" \
    </dev/null >>"$runtime/agent.log" 2>&1
