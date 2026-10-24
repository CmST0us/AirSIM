/* Standalone controller-run diagnostic: configuration only, never PCM I/O. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <tinyalsa/pcm.h>
#include <unistd.h>

static void json_string(const char *s, size_t n) {
  putchar('"');
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '"' || c == '\\') {
      putchar('\\');
      putchar(c);
    } else if (c < 32 || c >= 127) {
      printf("\\u%04x", c);
    } else {
      putchar(c);
    }
  }
  putchar('"');
}

static int inspect(unsigned device, unsigned direction, const char *path) {
  struct pcm_config requested = {.channels = 1,
                                 .rate = 8000,
                                 .period_size = 320,
                                 .period_count = 2,
                                 .format = PCM_FORMAT_S16_LE,
                                 .start_threshold =
                                     direction == PCM_IN ? 320 : 640,
                                 .stop_threshold = 640,
                                 .avail_min = 320};
  struct pcm *pcm =
      pcm_open(0, device, direction | PCM_NONBLOCK | PCM_NORESTART, &requested);
  int ready = pcm && pcm_is_ready(pcm);
  printf("{\"card\":0,\"device\":%u,\"direction\":\"%s\",\"open_ready\":%s",
         device, direction == PCM_IN ? "capture" : "playback",
         ready ? "true" : "false");
  if (ready) {
    const struct pcm_config *c = pcm_get_config(pcm);
    if (c) {
      printf(",\"pcm_config\":{\"channels\":%u,\"rate\":%u,"
             "\"format_enum\":%d,\"s16_le_enum\":%d,\"period_size\":%u,"
             "\"period_count\":%u,\"start_threshold\":%u,"
             "\"stop_threshold\":%u,\"silence_threshold\":%u,"
             "\"silence_size\":%u,\"avail_min\":%u}",
             c->channels, c->rate, c->format, PCM_FORMAT_S16_LE, c->period_size,
             c->period_count, c->start_threshold, c->stop_threshold,
             c->silence_threshold, c->silence_size, c->avail_min);
    }
    printf(",\"buffer_frames\":%u", pcm_get_buffer_size(pcm));
  }
  /* Fixed proc path; raw output is bounded and JSON escaped. No user data. */
  char raw[1024];
  size_t n = 0;
  int available = 0, truncated = 0;
  FILE *f = fopen(path, "r");
  if (f) {
    n = fread(raw, 1, sizeof(raw), f);
    available = !ferror(f);
    if (n == sizeof(raw))
      truncated = fgetc(f) != EOF;
    fclose(f);
  }
  printf(",\"hw_params_readable\":%s,\"hw_params_truncated\":%s,\"hw_params\":",
         available ? "true" : "false", truncated ? "true" : "false");
  json_string(raw, n);
  puts("}");
  fflush(stdout);
  if (pcm)
    pcm_close(pcm);
  return ready && available && !truncated ? 0 : 1;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("audio-config-probe 1 "
         "tinyalsa-1c5fb68ced57d838f2b7ecd0c00bc1fefc9ab60d");
    return 0;
  }
  if (argc != 1)
    return 2;
  signal(SIGALRM, SIG_DFL);
  alarm(5);
  int capture = inspect(9, PCM_IN, "/proc/asound/card0/pcm9c/sub0/hw_params");
  int playback =
      inspect(55, PCM_OUT, "/proc/asound/card0/pcm55p/sub0/hw_params");
  return capture || playback;
}
