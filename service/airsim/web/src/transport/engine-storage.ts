import { TransportFailure } from '../pairing';
import { platforms } from './platform';
import type { PlatformID } from './platform';

const reserveKiB = 512;
const frameBytes = 64 * 1024;

// Only installer-owned scratch files. Never glob configuration, state or logs.
const stagingNames = [
  'run-agent.sh', 'airsim-audiod', 'airsim-install.sh',
  'airsim_data11.ko', 'qdc507_aprv3.ko', 'qdc507_voice.ko',
  'COPYING-GPL-2.0', 'MODULE-REPORT.md', 'airsim_data11.c', 'isrgrootx1.pem',
  'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'OPUS-LICENSE.txt',
];

export function prepareEngineStorageScript(profile: PlatformID, _release: string, requiredBytes: number): string {
  return `
set -eu
base=${platforms[profile].base}
current="$(readlink -f "$base/current" 2>/dev/null || true)"
audio="$(readlink -f "$base/audio-current" 2>/dev/null || true)"
# A previous switch may have left the old process alive. Keep its executable too.
running=
for pid in $(pidof airsim-agent airsim-audiod 2>/dev/null || true); do
  executable="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  running="$running \${executable%/*}"
done
for directory in "$base"/releases/* "$base"/audio-releases/*; do
  [ -d "$directory" ] || continue
  [ ! -L "$directory" ] || continue
  resolved="$(readlink -f "$directory")"
  keep=0
  for pinned in "$current" "$audio" $running; do
    [ "$resolved" != "$pinned" ] || keep=1
  done
  if [ "$keep" = 0 ]; then
    rm -rf "$directory"
  else
    rm -f "$directory/.airsim-agent.new"
  fi
done
${stagingNames.map(name => `rm -f "$base/.${name}.new"`).join('\n')}
# Commit deletion before reading UBIFS's conservative free-space accounting.
sync
# Match the containing mount point, not the device alias printed by df.
filesystem="$(awk -v path="$base" '
  ($2 == "/" || path == $2 || index(path, $2 "/") == 1) && length($2) > longest {
    longest = length($2); type = $3
  }
  END { print type }
' /proc/mounts)"
required_kib=${Math.ceil(requiredBytes / 1024) + reserveKiB}
if [ "$filesystem" = ubifs ]; then
  # Compression is data-dependent. Admit the first bounded write, then measure.
  required_kib=${reserveKiB + (requiredBytes ? 4 : 0)}
fi
available_kib="$(df -Pk "$base" | awk 'NR == 2 { print $4 }')"
case "$available_kib" in
  ''|*[!0-9]*) echo AIRSIM_ENGINE_STORAGE_UNKNOWN; exit 1 ;;
esac
if [ "$available_kib" -lt "$required_kib" ]; then
  echo "AIRSIM_ENGINE_STORAGE_SHORT:$available_kib:$required_kib"
  exit 1
fi
echo AIRSIM_ENGINE_STORAGE_READY
`;
}

function storageShort(free: number, required: number): TransportFailure {
  return new TransportFailure('install_failed',
    `模块空间不足（剩余 ${free} KiB，本次写入至少需要 ${required} KiB，含 ${reserveKiB} KiB 安全余量）；当前运行版本已保留。`);
}

export function checkEngineStorage(output: string): void {
  const shortage = /^AIRSIM_ENGINE_STORAGE_SHORT:(\d+):(\d+)\r?$/m.exec(output);
  if (shortage) throw storageShort(Number(shortage[1]), Number(shortage[2]));
  if (!/^AIRSIM_ENGINE_STORAGE_READY\r?$/m.test(output)) {
    throw new TransportFailure('install_failed', '未能完成存储整理或读取剩余空间；当前运行版本已保留。');
  }
}

// Near the reserve, use whole 4 KiB filesystem blocks instead of rejecting a
// 64 KiB frame that could still fit after UBIFS compression. Never lower reserve.
export function engineWriteSize(output: string, remaining: number): number {
  const text = output.trim();
  if (!/^\d+$/.test(text) || !Number.isSafeInteger(Number(text))) {
    throw new TransportFailure('install_failed', '无法读取模块剩余空间；当前运行版本已保留。');
  }
  const free = Number(text);
  const minimum = remaining > 0 ? Math.min(4096, remaining) : 0;
  if (free < reserveKiB + Math.ceil(minimum / 1024)) {
    throw storageShort(free, reserveKiB + Math.ceil(minimum / 1024));
  }
  if (!remaining) return 0;
  const budget = Math.floor((free - reserveKiB) / 4) * 4096;
  return Math.min(remaining, frameBytes, Math.max(minimum, budget));
}
