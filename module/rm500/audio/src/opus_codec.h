#ifndef AIRSIM_OPUS_CODEC_H
#define AIRSIM_OPUS_CODEC_H
#include <stdint.h>

/* One 20 ms frame of 16 kHz mono S16LE per packet. */
enum {
  AIRSIM_OPUS_SAMPLE_RATE = 16000,
  AIRSIM_OPUS_FRAME_SAMPLES = 320,
  AIRSIM_OPUS_PCM_BYTES = 640,
  AIRSIM_OPUS_MAX_PACKET = 1275
};
/* How the decoder uses a packet: decode it, conceal a lost frame, or rebuild
 * the lost frame from the in-band FEC of the following packet. */
enum { AIRSIM_OPUS_PACKET = 0, AIRSIM_OPUS_ERASURE = 1, AIRSIM_OPUS_FEC = 2 };
/* Stack for a thread that encodes or decodes, with wide margin over libopus'
 * per-frame allocations. The default 8 MB stack is not always reservable on
 * a module with a few MB of free memory. */
enum { AIRSIM_OPUS_THREAD_STACK = 256 * 1024 };

typedef struct OpusEncoder airsim_opus_encoder;
typedef struct OpusDecoder airsim_opus_decoder;

airsim_opus_encoder *airsim_opus_encoder_create(void);
airsim_opus_decoder *airsim_opus_decoder_create(void);
void airsim_opus_encoder_destroy(airsim_opus_encoder *);
void airsim_opus_decoder_destroy(airsim_opus_decoder *);
/* Returns the packet length, or -1. */
int airsim_opus_encode(airsim_opus_encoder *, const uint8_t pcm[AIRSIM_OPUS_PCM_BYTES],
                       uint8_t packet[AIRSIM_OPUS_MAX_PACKET]);
/* Returns 0 for a decoded packet, 1 when the frame was concealed or rebuilt,
 * and -1 on error. A packet that does not decode to exactly one frame is
 * concealed. */
int airsim_opus_decode(airsim_opus_decoder *, const uint8_t *packet, int size, int kind,
                       uint8_t pcm[AIRSIM_OPUS_PCM_BYTES]);
#endif
