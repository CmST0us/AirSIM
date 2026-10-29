export const platforms = {
  'rm500u-embedded': { name: 'RM500U', arch: 'arm64', base: '/mnt/data/airsim-v2' },
  'eg25-qdc507': { name: 'EG25 QDC507', arch: 'arm', base: '/usrdata/airsim-v2' },
} as const;
export type PlatformID = keyof typeof platforms;

export function isPlatform(value: string): value is PlatformID {
  return Object.hasOwn(platforms, value);
}

export function detectPlatform(values: Map<string, string>): PlatformID | undefined {
  if (values.get('os') !== 'Linux' || values.get('uid') !== '0') return undefined;
  if (['aarch64', 'arm64'].includes(values.get('arch') || '') && values.get('host') === 'udx710-module') {
    return 'rm500u-embedded';
  }
  if (values.get('arch') === 'armv7l' && values.get('kernel') === '3.18.44'
    && values.get('project') === 'EG25G_QDC507'
    && values.get('firmware') === 'QDC507GLEFM21_02.004.03') return 'eg25-qdc507';
  return undefined;
}

export const hardwareScript = `
printf 'os=%s\\n' "$(uname -s)"
printf 'arch=%s\\n' "$(uname -m)"
printf 'kernel=%s\\n' "$(uname -r)"
printf 'host=%s\\n' "$(hostname)"
printf 'uid=%s\\n' "$(id -u)"
awk -F: '/^Project Name:/ {gsub(/^[ \\t]+|[ \\t\\r]+$/, "", $2); print "project=" $2} /^Project Sub Rev :/ {gsub(/^[ \\t]+|[ \\t\\r]+$/, "", $2); print "firmware=" $2}' /etc/quectel-project-subversion 2>/dev/null || true
`;

export function parseProperties(output: string): Map<string,string> {
  return new Map(output.split(/\r?\n/).filter(line => line.includes('='))
    .map(line => [line.slice(0,line.indexOf('=')), line.slice(line.indexOf('=')+1)]));
}
