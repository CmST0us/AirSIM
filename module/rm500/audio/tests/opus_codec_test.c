#include "opus_codec.h"
#include "opus.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define FRAMES 100
#define SAMPLES (FRAMES * AIRSIM_OPUS_FRAME_SAMPLES)

/* Voiced speech stand-in: phase-continuous harmonics whose pitch and level
 * change every frame, so concealment cannot simply repeat the last period. */
static int16_t source[SAMPLES], decoded[SAMPLES];
static void synthesize(void) {
  double phase = 0;
  for (int f = 0; f < FRAMES; f++) {
    double f0 = 150 + 60 * sin(f * 0.7), level = 0.6 + 0.4 * sin(f * 0.3);
    for (int i = 0; i < AIRSIM_OPUS_FRAME_SAMPLES; i++) {
      phase += 2 * M_PI * f0 / AIRSIM_OPUS_SAMPLE_RATE;
      double v = 0;
      for (int h = 1; h <= 8; h++)
        v += sin(h * phase) / h;
      source[f * AIRSIM_OPUS_FRAME_SAMPLES + i] = (int16_t)(v * 4000 * level);
    }
  }
}
static void to_pcm(const int16_t *s, uint8_t pcm[AIRSIM_OPUS_PCM_BYTES]) {
  for (int i = 0; i < AIRSIM_OPUS_FRAME_SAMPLES; i++) {
    pcm[2 * i] = (uint8_t)s[i];
    pcm[2 * i + 1] = (uint8_t)((uint16_t)s[i] >> 8);
  }
}
static void from_pcm(const uint8_t pcm[AIRSIM_OPUS_PCM_BYTES], int16_t *s) {
  for (int i = 0; i < AIRSIM_OPUS_FRAME_SAMPLES; i++)
    s[i] = (int16_t)((uint16_t)pcm[2 * i] | (uint16_t)pcm[2 * i + 1] << 8);
}
/* Error energy of decoded samples [from, to) against the delayed source. */
static double error(int from, int to, int delay) {
  double e = 0;
  for (int i = from; i < to; i++) {
    double d = (double)source[i - delay] - decoded[i];
    e += d * d;
  }
  return e / (to - from);
}

static void *run(void *unused) {
  (void)unused;
  static uint8_t packets[FRAMES][AIRSIM_OPUS_MAX_PACKET];
  int sizes[FRAMES];
  uint8_t pcm[AIRSIM_OPUS_PCM_BYTES];
  synthesize();
  airsim_opus_encoder *enc = airsim_opus_encoder_create();
  assert(enc);
  int application = 0;
  assert(opus_encoder_ctl(enc, OPUS_GET_APPLICATION(&application)) == OPUS_OK);
  assert(application == OPUS_APPLICATION_AUDIO);
  long total = 0;
  for (int f = 0; f < FRAMES; f++) {
    to_pcm(source + f * AIRSIM_OPUS_FRAME_SAMPLES, pcm);
    sizes[f] = airsim_opus_encode(enc, pcm, packets[f]);
    assert(sizes[f] > 0 && sizes[f] < 400);
    total += sizes[f];
  }
  airsim_opus_encoder_destroy(enc);
  /* A 96 kbps target budgets 240 bytes per 20 ms; VBR spends less on this
   * synthetic voice. Catch a regression to the former 32/64 kbps targets. */
  double average = (double)total / FRAMES;
  assert(average > 150 && average < 260);

  airsim_opus_decoder *dec = airsim_opus_decoder_create();
  assert(dec);
  for (int f = 0; f < FRAMES; f++) {
    assert(airsim_opus_decode(dec, packets[f], sizes[f], AIRSIM_OPUS_PACKET, pcm) == 0);
    from_pcm(pcm, decoded + f * AIRSIM_OPUS_FRAME_SAMPLES);
  }
  airsim_opus_decoder_destroy(dec);
  int from = 20 * AIRSIM_OPUS_FRAME_SAMPLES, to = 80 * AIRSIM_OPUS_FRAME_SAMPLES, delay = 0;
  double best = -1;
  for (int d = 0; d < 300; d++) {
    double xy = 0, xx = 0, yy = 0;
    for (int i = from; i < to; i++) {
      xy += (double)source[i - d] * decoded[i];
      xx += (double)source[i - d] * source[i - d];
      yy += (double)decoded[i] * decoded[i];
    }
    if (xy / sqrt(xx * yy) > best) {
      best = xy / sqrt(xx * yy);
      delay = d;
    }
  }
  double signal = 0;
  for (int i = from; i < to; i++)
    signal += (double)source[i - delay] * source[i - delay];
  double snr = 10 * log10(signal / (to - from) / error(from, to, delay));
  printf("opus wideband: %.1f bytes/frame, delay %d, correlation %.3f, SNR %.1f dB\n", average, delay, best, snr);
  /* This synthetic phase-continuous signal detects unintended input shaping.
   * It is not a speech MOS or a claim about real cellular audio quality. */
  assert(best > 0.99 && snr > 25);

  /* Lose frame 50: FEC from frame 51 rebuilds it closer than concealment. */
  int lost = 50 * AIRSIM_OPUS_FRAME_SAMPLES;
  double rebuilt[2];
  for (int mode = 0; mode < 2; mode++) {
    dec = airsim_opus_decoder_create();
    for (int f = 0; f < 50; f++)
      assert(airsim_opus_decode(dec, packets[f], sizes[f], AIRSIM_OPUS_PACKET, pcm) == 0);
    if (mode == 0)
      assert(airsim_opus_decode(dec, packets[51], sizes[51], AIRSIM_OPUS_FEC, pcm) == 1);
    else
      assert(airsim_opus_decode(dec, NULL, 0, AIRSIM_OPUS_ERASURE, pcm) == 1);
    from_pcm(pcm, decoded + lost);
    rebuilt[mode] = error(lost, lost + AIRSIM_OPUS_FRAME_SAMPLES, delay);
    assert(airsim_opus_decode(dec, packets[51], sizes[51], AIRSIM_OPUS_PACKET, pcm) == 0);
    airsim_opus_decoder_destroy(dec);
  }
  printf("lost frame error: fec %.0f, plc %.0f\n", rebuilt[0], rebuilt[1]);
  assert(rebuilt[0] < rebuilt[1]);

  /* A packet that is not one 20 ms frame is concealed, never played. */
  dec = airsim_opus_decoder_create();
  uint8_t long_packet[3] = {(uint8_t)(packets[0][0] | 0x03), 0x02, 0};
  assert(airsim_opus_decode(dec, long_packet, 3, AIRSIM_OPUS_PACKET, pcm) == 1);
  assert(airsim_opus_decode(dec, packets[0], 0, AIRSIM_OPUS_PACKET, pcm) == 1);
  airsim_opus_decoder_destroy(dec);
  return NULL;
}

/* The codec runs on a thread with the stack the helper gives its workers. */
int main(void) {
  pthread_attr_t attr;
  pthread_t thread;
  assert(pthread_attr_init(&attr) == 0);
  assert(pthread_attr_setstacksize(&attr, AIRSIM_OPUS_THREAD_STACK) == 0);
  assert(pthread_create(&thread, &attr, run, NULL) == 0);
  assert(pthread_join(thread, NULL) == 0);
  puts("Opus encode, decode, FEC and concealment tests passed");
  return 0;
}
