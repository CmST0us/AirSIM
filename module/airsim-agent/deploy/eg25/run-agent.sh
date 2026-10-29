#!/bin/sh
set -eu
umask 077
base=/usrdata/airsim-v2
run=/run/airsim-v2
platform="$base/platform"
test "$(uname -m)" = armv7l
test "$(uname -r)" = 3.18.44
grep -q '^Project Name: EG25G_QDC507$' /etc/quectel-project-subversion
grep -q '^Project Sub Rev : QDC507GLEFM21_02.004.03$' /etc/quectel-project-subversion
mkdir -p "$run" /run/lock
chmod 700 "$run"
mkdir -p "$run/certs"
cp "$platform/isrgrootx1.pem" "$run/certs/isrgrootx1.pem"
export SSL_CERT_DIR="$run/certs"

for module in airsim_data11 qdc507_aprv3 qdc507_voice; do
  if ! grep -q "^$module " /proc/modules; then
    insmod "$platform/$module.ko"
  fi
done
if [ ! -c /dev/airsim_data11 ]; then
  device=$(cat /sys/class/misc/airsim_data11/dev)
  mknod /dev/airsim_data11 c "${device%:*}" "${device#*:}"
fi
chmod 600 /dev/airsim_data11

g=/sys/class/android_usb/android0
functions=$(cat "$g/functions")
case "$functions" in
  diag,serial,ecm,ffs)
    printf '%s\n' "$functions" > "$run/usb-functions"
    echo 0 > "$g/enable"
    echo diag,ecm,ffs > "$g/functions"
    ;;
  diag,ecm,ffs) ;;
  *) echo 'airsim: unsupported USB composition' >&2; exit 1 ;;
esac
driver=/sys/bus/platform/drivers/DATA11
if [ -L "$driver/DATA11.0" ]; then
  echo DATA11.0 > "$driver/unbind"
fi
if [ "$(cat "$g/enable")" != 1 ]; then echo 1 > "$g/enable"; fi
if [ "$(cat /sys/class/android_usb/f_audio/audio_enable)" != 1 ]; then
  echo 1 > /sys/class/android_usb/f_audio/audio_enable
fi

log=/run/airsim-calibration.log
if ! grep -qF 'ACDB -> Sent VocProc Cal!' "$log" 2>/dev/null; then
  if [ -p /run/alsaucm_test ]; then
    echo 'airsim: calibration is owned by another runtime' >&2
    exit 1
  fi
  /usr/bin/alsaucm_test </dev/null >"$log" 2>&1 &
  echo "$!" > "$run/calibration.pid"
  n=0
  until [ -p /run/alsaucm_test ]; do
    n=$((n + 1)); [ "$n" -lt 10 ] || exit 1; sleep 1
  done
  printf 'open snd_soc_msm_9x07_Tomtom_I2S\nset _verb VoLTE\nset _enadev Auxpcm Rx\nset _enadev Auxpcm Tx\n' > /run/alsaucm_test
  n=0
  until grep -qF 'ACDB -> Sent VocProc Cal!' "$log"; do
    n=$((n + 1)); [ "$n" -lt 15 ] || exit 1; sleep 1
  done
fi

exec "$base/current/airsim-agent" --profile eg25-qdc507 \
  --at-device /dev/airsim_data11 --data-dir "$base" --runtime-dir "$run" \
  --audio-helper "$base/audio-current/airsim-audiod" </dev/null >>"$run/agent.log" 2>&1
