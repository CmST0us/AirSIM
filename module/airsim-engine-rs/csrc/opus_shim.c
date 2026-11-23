#include "opus.h"
#include <stddef.h>
#include <stdint.h>

OpusEncoder *airsim_rs_opus_encoder_create(void) {
  int err = 0;
  OpusEncoder *e = opus_encoder_create(16000, 1, OPUS_APPLICATION_AUDIO, &err);
  if (!e || err != OPUS_OK) {
    return NULL;
  }
  if (opus_encoder_ctl(e, OPUS_SET_BITRATE(64000)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_VBR(1)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(4)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_WIDEBAND)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_INBAND_FEC(1)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_PACKET_LOSS_PERC(5)) != OPUS_OK ||
      opus_encoder_ctl(e, OPUS_SET_DTX(0)) != OPUS_OK) {
    opus_encoder_destroy(e);
    return NULL;
  }
  return e;
}

void airsim_rs_opus_encoder_destroy(OpusEncoder *e) {
  if (e) {
    opus_encoder_destroy(e);
  }
}

int airsim_rs_opus_encode(OpusEncoder *e, const int16_t *pcm, int frame_size,
                          uint8_t *out, int max_out) {
  return opus_encode(e, pcm, frame_size, out, max_out);
}

OpusDecoder *airsim_rs_opus_decoder_create(void) {
  int err = 0;
  OpusDecoder *d = opus_decoder_create(16000, 1, &err);
  if (!d || err != OPUS_OK) {
    return NULL;
  }
  return d;
}

void airsim_rs_opus_decoder_destroy(OpusDecoder *d) {
  if (d) {
    opus_decoder_destroy(d);
  }
}

int airsim_rs_opus_packet_nb_samples(const uint8_t *packet, int len, int fs) {
  if (!packet || len <= 0) {
    return -1;
  }
  return opus_packet_get_nb_samples(packet, len, fs);
}

int airsim_rs_opus_decode(OpusDecoder *d, const uint8_t *packet, int len,
                          int16_t *pcm, int frame_size, int decode_fec) {
  return opus_decode(d, packet, len, pcm, frame_size, decode_fec);
}
