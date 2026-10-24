#include "audio_format.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void put(uint8_t *p, int16_t x) {
  p[0] = (uint8_t)x;
  p[1] = (uint8_t)((uint16_t)x >> 8);
}
static int16_t get(uint8_t *p) {
  unsigned u = p[0] | (unsigned)p[1] << 8;
  return (int16_t)(u >= 32768 ? (int)u - 65536 : (int)u);
}
static void source(const char *path, const char *text) {
  FILE *f = fopen(path, "w");
  assert(f);
  assert(fputs(text, f) >= 0);
  fclose(f);
}
int main(void) {
  uint8_t buf[640], original[320];
  int16_t samples[160], previous = 0;
  for (int i = 0; i < 160; i++) {
    samples[i] = (int16_t)(i % 4 == 0   ? 32767
                           : i % 4 == 1 ? -32768
                           : i % 4 == 2 ? 3
                                        : -2);
    put(buf + 2 * i, samples[i]);
  }
  memcpy(original, buf, 320);
  assert(audio_expand(buf, 8000, &previous) == 160 &&
         !memcmp(buf, original, 320));
  assert(audio_expand(buf, 16000, &previous) == 320);
  for (int i = 0; i < 160; i++) {
    int32_t p = i ? samples[i - 1] : 0;
    assert(get(buf + 4 * i) == (p + samples[i]) / 2);
    assert(get(buf + 4 * i + 2) == samples[i]);
  }
  assert(previous == samples[159]);
  memset(buf, 0, sizeof(buf));
  int16_t saved = previous;
  assert(audio_expand(buf, 16000, &previous) == 320 && get(buf) == saved / 2 &&
         previous == 0);
  for (unsigned i = 2; i < sizeof(buf); i++)
    assert(buf[i] == 0);
  previous = 0;
  memset(buf, 0, sizeof(buf));
  audio_expand(buf, 16000, &previous);
  for (unsigned i = 0; i < sizeof(buf); i++)
    assert(buf[i] == 0);
  char path[] = "/tmp/airsim-clock-test-XXXXXX";
  int fd = mkstemp(path);
  assert(fd >= 0);
  close(fd);
  const char *good8 = "access: RW_INTERLEAVED\nformat: S16_LE\nchannels: "
                      "1\nrate: 8000 (8000/1)\n";
  const char *good16 = "format: S16_LE\nchannels: 1\nrate: 16000 (16000/1)\n";
  unsigned rate = 0;
  source(path, good8);
  assert(!audio_voice_rate(path, &rate) && rate == 8000);
  assert(!audio_voice_unchanged(path, 8000));
  source(path, good16);
  assert(!audio_voice_rate(path, &rate) && rate == 16000);
  assert(audio_voice_unchanged(path, 8000) == -1);
  const char *bad[] = {
      "closed\n",
      "format: S16_LE\nchannels: 2\nrate: 16000\n",
      "format: S32_LE\nchannels: 1\nrate: 16000\n",
      "format: S16_LE\nchannels: 1\nrate: 48000\n",
      "format: S16_LE\nchannels: 1\nrate: 16000oops\n",
      "format: S16_LE\nchannels: 1\nrate: 16000 (8000/1)\n",
      "format: S16_LE\nchannels: 1\nrate: 16000\nrate: 16000\n",
      "format: S16_LE\nrate: 8000\n",
      ""};
  for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    source(path, bad[i]);
    assert(audio_voice_rate(path, &rate) == -1);
    assert(audio_voice_unchanged(path, 16000) == -1);
  }
  char huge[4200];
  memset(huge, 'x', sizeof(huge) - 1);
  huge[sizeof(huge) - 1] = 0;
  source(path, huge);
  assert(audio_voice_rate(path, &rate) == -1);
  unlink(path);
  assert(audio_voice_rate(path, &rate) == -1);
  puts("native interpolation, strict voice clock parsing and change rejection "
       "passed");
}
