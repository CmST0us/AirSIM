#define _GNU_SOURCE
#include "../route.h"
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <tinyalsa/pcm.h>

/* In-call wideband diagnostic. Received PCM stays in memory and is reduced to
 * band energies; the transmit side carries only synthetic tones. */
#define BLOCK 256
#define BANDS 5
static const double edges[BANDS + 1] = {0, 300, 3400, 4000, 7000, 8000};

static double now_s(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static void print_rate(const char *name, const char *path) {
  char line[128];
  unsigned rate = 0;
  FILE *f = fopen(path, "r");
  while (f && fgets(line, sizeof(line), f)) sscanf(line, "rate: %u", &rate);
  if (f) fclose(f);
  printf("\"%s_rate\":%u,", name, rate);
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  unsigned rate = (unsigned)atoi(argv[1]);
  int seconds = atoi(argv[2]);
  if ((rate != 8000 && rate != 16000) || seconds < 1 || seconds > 30) return 2;
  if (eg25_audio_start_rate(rate)) {
    printf("{\"rate\":%u,\"error\":\"route_start\"}\n", rate);
    eg25_audio_stop();
    return 1;
  }
  struct pcm_config config = {.channels = 1, .rate = rate, .period_size = 256,
      .period_count = 8, .format = PCM_FORMAT_S16_LE, .start_threshold = 256,
      .stop_threshold = 2048, .avail_min = 256};
  struct pcm *cap = pcm_open(0, 6, PCM_IN | PCM_MMAP | PCM_NONBLOCK | PCM_NORESTART, &config);
  config.start_threshold = 512;
  struct pcm *play = pcm_open(0, 5, PCM_OUT | PCM_MMAP | PCM_NONBLOCK | PCM_NORESTART, &config);
  int ok = cap && pcm_is_ready(cap) && play && pcm_is_ready(play) &&
           !pcm_prepare(cap) && !pcm_prepare(play) && !pcm_start(cap);
  printf("{\"rate\":%u,\"open\":%s,", rate, ok ? "true" : "false");
  print_rate("voice_playback", "/proc/asound/card0/pcm4p/sub0/hw_params");
  print_rate("voice_capture", "/proc/asound/card0/pcm4c/sub0/hw_params");
  print_rate("proxy_rx", "/proc/asound/card0/pcm5p/sub0/hw_params");
  print_rate("proxy_tx", "/proc/asound/card0/pcm6c/sub0/hw_params");
  double cosv[BLOCK], sinv[BLOCK], win[BLOCK], band[BANDS] = {0}, block[BLOCK];
  for (int i = 0; i < BLOCK; i++) {
    cosv[i] = cos(2 * M_PI * i / BLOCK);
    sinv[i] = sin(2 * M_PI * i / BLOCK);
    win[i] = 0.5 - 0.5 * cos(2 * M_PI * i / BLOCK);
  }
  unsigned long captured = 0, played = 0, speech = 0, blocks = 0;
  unsigned xruns = 0, fill = 0;
  int peak = 0;
  int16_t in[BLOCK], out[160];
  double start = now_s(), phase = 0;
  while (ok && now_s() - start < seconds) {
    int n = pcm_readi(cap, in, BLOCK - fill);
    if (n < 0 && (errno == EPIPE || errno == ESTRPIPE)) {
      xruns++;
      pcm_prepare(cap);
      pcm_start(cap);
    }
    for (int i = 0; i < n; i++) {
      block[fill++] = in[i] / 32768.0;
      if (abs(in[i]) > peak) peak = abs(in[i]);
    }
    if (n > 0) captured += (unsigned long)n;
    if (fill == BLOCK) {
      fill = 0;
      blocks++;
      double energy = 0;
      for (int i = 0; i < BLOCK; i++) energy += block[i] * block[i];
      if (energy / BLOCK > 1e-5) { /* about -50 dBFS: speech, not idle noise */
        speech++;
        for (int k = 1; k < BLOCK / 2; k++) {
          double re = 0, im = 0;
          for (int i = 0; i < BLOCK; i++) {
            unsigned j = (unsigned)(i * k) % BLOCK;
            re += block[i] * win[i] * cosv[j];
            im -= block[i] * win[i] * sinv[j];
          }
          double hz = (double)k * rate / BLOCK;
          for (int b = 0; b < BANDS; b++)
            if (hz >= edges[b] && hz < edges[b + 1]) band[b] += re * re + im * im;
        }
      }
    }
    /* Tones: 1 kHz for 3 s, silence for 3 s, then 6 kHz (16 kHz runs only). */
    double t = (double)played / rate;
    double hz = t < 3 ? 1000 : (t < 6 || rate == 8000) ? 0 : 6000;
    for (int i = 0; i < 160; i++) {
      out[i] = hz ? (int16_t)(8000 * sin(phase)) : 0;
      phase = fmod(phase + 2 * M_PI * hz / rate, 2 * M_PI);
    }
    int w = pcm_writei(play, out, 160);
    if (w > 0) played += (unsigned long)w;
    else if (w < 0 && (errno == EPIPE || errno == ESTRPIPE)) { xruns++; pcm_prepare(play); }
    struct timespec pause = {0, 2000000};
    nanosleep(&pause, NULL);
  }
  double total = 0;
  for (int b = 0; b < BANDS; b++) total += band[b];
  printf("\"captured\":%lu,\"played\":%lu,\"xruns\":%u,\"peak\":%d,\"blocks\":%lu,\"speech_blocks\":%lu,\"band_db\":{",
         captured, played, xruns, peak, blocks, speech);
  for (int b = 0; b < BANDS; b++)
    printf("%s\"%.0f-%.0f\":%.1f", b ? "," : "", edges[b], edges[b + 1],
           total > 0 && band[b] > 0 ? 10 * log10(band[b] / total) : -99.0);
  printf("}}\n");
  if (play) pcm_close(play);
  if (cap) pcm_close(cap);
  eg25_audio_stop();
  return ok ? 0 : 1;
}
