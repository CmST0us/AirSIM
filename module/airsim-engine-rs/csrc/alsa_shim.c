#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <tinyalsa/pcm.h>
#include "route.h"

struct pcm *airsim_rs_pcm_open(unsigned card, unsigned device, unsigned flags,
                               unsigned rate, unsigned period_size,
                               unsigned period_count, unsigned start_threshold,
                               unsigned stop_threshold, unsigned avail_min) {
  struct pcm_config config;
  config.channels = 1;
  config.rate = rate;
  config.period_size = period_size;
  config.period_count = period_count;
  config.format = PCM_FORMAT_S16_LE;
  config.start_threshold = start_threshold;
  config.stop_threshold = stop_threshold;
  config.silence_threshold = 0;
  config.silence_size = 0;
  config.avail_min = avail_min;
  struct pcm *p = pcm_open(card, device, flags, &config);
  if (!p) {
    return NULL;
  }
  if (!pcm_is_ready(p)) {
    pcm_close(p);
    return NULL;
  }
  return p;
}

int airsim_rs_pcm_close(struct pcm *p) { return p ? pcm_close(p) : 0; }
int airsim_rs_pcm_prepare(struct pcm *p) { return pcm_prepare(p); }
int airsim_rs_pcm_start(struct pcm *p) { return pcm_start(p); }
int airsim_rs_pcm_poll_fd(struct pcm *p) { return pcm_get_poll_fd(p); }
long airsim_rs_pcm_delay(struct pcm *p) { return pcm_get_delay(p); }
unsigned airsim_rs_pcm_buffer_size(struct pcm *p) { return pcm_get_buffer_size(p); }

int airsim_rs_pcm_readi(struct pcm *p, void *data, unsigned frames, int *out_errno) {
  errno = 0;
  int n = pcm_readi(p, data, frames);
  if (out_errno) *out_errno = errno;
  return n;
}

int airsim_rs_pcm_writei(struct pcm *p, const void *data, unsigned frames, int *out_errno) {
  errno = 0;
  int n = pcm_writei(p, data, frames);
  if (out_errno) *out_errno = errno;
  return n;
}

int airsim_rs_eg25_route_start(unsigned rate) { return eg25_audio_start_rate(rate); }
void airsim_rs_eg25_route_stop(void) { eg25_audio_stop(); }
int airsim_rs_eg25_route_reset(void) { return eg25_audio_reset(); }
