#ifndef AIRSIM_AUDIO_FORMAT_H
#define AIRSIM_AUDIO_FORMAT_H
#include <stdint.h>
/* Strict bounded proc reader: only S16_LE mono 8/16kHz. */
int audio_voice_rate(const char *path, unsigned *rate);
int audio_voice_unchanged(const char *path, unsigned expected);
/* 320-byte external frame in a 640-byte working area; returns native frames. */
unsigned audio_expand(uint8_t data[640], unsigned rate, int16_t *previous);
#endif
