#ifndef AIRSIM_AUDIO_FORMAT_H
#define AIRSIM_AUDIO_FORMAT_H
#include <stdint.h>
/* Strict bounded proc reader: only S16_LE mono 8/16kHz. */
int audio_voice_rate(const char *path, unsigned *rate);
int audio_voice_unchanged(const char *path, unsigned expected);
/* 160 samples at 8 kHz in a 640-byte working area; returns frames at rate. */
unsigned audio_expand(uint8_t data[640], unsigned rate, int16_t *previous);
/* 320 samples at 16 kHz; for 8 kHz output, low-pass and decimate in place. */
unsigned audio_reduce(uint8_t data[640], unsigned rate, int16_t *previous);
/* Apply -3 dB linear headroom + C1-continuous soft-knee peak limiting before
 * feeding QDSP6 Handset Tx calibration, preventing hot VPIO speech clipping. */
void audio_condition_uplink_pcm(uint8_t *data, unsigned samples);
#endif
