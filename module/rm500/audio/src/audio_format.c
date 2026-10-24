#include "audio_format.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>
static int end(const char *s) {
  while (isspace((unsigned char)*s))
    s++;
  return *s == 0;
}
int audio_voice_rate(const char *path, unsigned *rate) {
  FILE *f = fopen(path, "r");
  if (!f)
    return -1;
  char text[4097];
  size_t n = fread(text, 1, sizeof(text), f);
  int bad = ferror(f) || n == sizeof(text);
  fclose(f);
  if (bad || memchr(text, 0, n))
    return -1;
  text[n] = 0;
  unsigned found = 0, r = 0;
  char *save = NULL;
  for (char *line = strtok_r(text, "\n", &save); line;
       line = strtok_r(NULL, "\n", &save)) {
    int used = 0;
    if (!strncmp(line, "format:", 7)) {
      char fmt[32];
      if ((found & 1) || sscanf(line, "format: %31s%n", fmt, &used) != 1 ||
          strcmp(fmt, "S16_LE") || !end(line + used))
        return -1;
      found |= 1;
    } else if (!strncmp(line, "channels:", 9)) {
      if ((found & 2) || strncmp(line, "channels: 1", 11) || !end(line + 11))
        return -1;
      found |= 2;
    } else if (!strncmp(line, "rate:", 5)) {
      /* ALSA prints either integer alone or integer followed by (rate/1). */
      if (found & 4)
        return -1;
      const char *v = line + 5;
      while (*v == ' ' || *v == '\t')
        v++;
      if (!strncmp(v, "8000", 4)) {
        r = 8000;
        v += 4;
      } else if (!strncmp(v, "16000", 5)) {
        r = 16000;
        v += 5;
      } else
        return -1;
      if (!end(v)) {
        unsigned numerator, denominator;
        if (sscanf(v, " (%u/%u)%n", &numerator, &denominator, &used) != 2 ||
            !used || numerator != r || denominator != 1 || !end(v + used))
          return -1;
      }
      found |= 4;
    } else if (!strcmp(line, "closed"))
      return -1;
  }
  if (found != 7)
    return -1;
  *rate = r;
  return 0;
}
int audio_voice_unchanged(const char *path, unsigned expected) {
  unsigned actual;
  return audio_voice_rate(path, &actual) || actual != expected ? -1 : 0;
}
static int16_t get(const uint8_t *p) {
  uint16_t u = (uint16_t)p[0] | (uint16_t)p[1] << 8;
  return (int16_t)(u >= 32768 ? (int32_t)u - 65536 : u);
}
static void put(uint8_t *p, int32_t value) {
  uint16_t u = (uint16_t)value;
  p[0] = (uint8_t)u;
  p[1] = (uint8_t)(u >> 8);
}
unsigned audio_expand(uint8_t data[640], unsigned rate, int16_t *previous) {
  if (rate == 8000)
    return 160;
  int16_t last = get(data + 318);
  for (int i = 159; i >= 0; i--) {
    int32_t x = get(data + i * 2);
    int32_t prev = i ? get(data + (i - 1) * 2) : *previous;
    put(data + i * 4 + 2, x);
    put(data + i * 4, (prev + x) / 2);
  }
  *previous = last;
  return 320;
}
