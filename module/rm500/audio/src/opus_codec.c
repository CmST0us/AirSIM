#include "opus_codec.h"
#include "opus.h"
#include <stddef.h>

/* Wideband voice at 32 kbps VBR with in-band FEC. Complexity 3 keeps the
 * fixed-point encoder and decoder near 1.5 ms per frame on a Cortex-A7. */
airsim_opus_encoder *airsim_opus_encoder_create(void) {
  int error = 0;
  OpusEncoder *e = opus_encoder_create(AIRSIM_OPUS_SAMPLE_RATE, 1, OPUS_APPLICATION_VOIP, &error);
  if (!e || error != OPUS_OK)
    return NULL;
  if (opus_encoder_ctl(e, OPUS_SET_BITRATE(32000)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_VBR(1)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(3)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_INBAND_FEC(1)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_PACKET_LOSS_PERC(10)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_DTX(0)) != OPUS_OK) {
    opus_encoder_destroy(e);
    return NULL;
  }
  return e;
}
airsim_opus_decoder *airsim_opus_decoder_create(void) {
  int error = 0;
  OpusDecoder *d = opus_decoder_create(AIRSIM_OPUS_SAMPLE_RATE, 1, &error);
  if (!d || error != OPUS_OK)
    return NULL;
  return d;
}
void airsim_opus_encoder_destroy(airsim_opus_encoder *e) {
  if (e)
    opus_encoder_destroy(e);
}
void airsim_opus_decoder_destroy(airsim_opus_decoder *d) {
  if (d)
    opus_decoder_destroy(d);
}
int airsim_opus_encode(airsim_opus_encoder *e, const uint8_t pcm[AIRSIM_OPUS_PCM_BYTES],
                       uint8_t packet[AIRSIM_OPUS_MAX_PACKET]) {
  opus_int16 samples[AIRSIM_OPUS_FRAME_SAMPLES];
  for (int i = 0; i < AIRSIM_OPUS_FRAME_SAMPLES; i++)
    samples[i] = (opus_int16)((uint16_t)pcm[2 * i] | (uint16_t)pcm[2 * i + 1] << 8);
  int n = opus_encode(e, samples, AIRSIM_OPUS_FRAME_SAMPLES, packet, AIRSIM_OPUS_MAX_PACKET);
  return n > 0 ? n : -1;
}
int airsim_opus_decode(airsim_opus_decoder *d, const uint8_t *packet, int size, int kind,
                       uint8_t pcm[AIRSIM_OPUS_PCM_BYTES]) {
  opus_int16 samples[AIRSIM_OPUS_FRAME_SAMPLES];
  int concealed = kind != AIRSIM_OPUS_PACKET;
  int n = -1;
  if (kind != AIRSIM_OPUS_ERASURE && packet && size > 0 &&
      opus_packet_get_nb_samples(packet, size, AIRSIM_OPUS_SAMPLE_RATE) == AIRSIM_OPUS_FRAME_SAMPLES)
    n = opus_decode(d, packet, size, samples, AIRSIM_OPUS_FRAME_SAMPLES, kind == AIRSIM_OPUS_FEC);
  if (n != AIRSIM_OPUS_FRAME_SAMPLES) {
    concealed = 1;
    n = opus_decode(d, NULL, 0, samples, AIRSIM_OPUS_FRAME_SAMPLES, 0);
  }
  if (n != AIRSIM_OPUS_FRAME_SAMPLES)
    return -1;
  for (int i = 0; i < AIRSIM_OPUS_FRAME_SAMPLES; i++) {
    uint16_t v = (uint16_t)samples[i];
    pcm[2 * i] = (uint8_t)v;
    pcm[2 * i + 1] = (uint8_t)(v >> 8);
  }
  return concealed;
}
