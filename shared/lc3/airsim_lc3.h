#ifndef AIRSIM_LC3_H
#define AIRSIM_LC3_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    AIRSIM_LC3_SAMPLE_RATE = 16000,
    AIRSIM_LC3_FRAME_US = 10000,
    AIRSIM_LC3_FRAME_SAMPLES = 160,
    AIRSIM_LC3_FRAME_BYTES = 40,
    AIRSIM_LC3_PACKET_SAMPLES = 320,
    AIRSIM_LC3_PCM_BYTES = 640,
    AIRSIM_LC3_PACKET_BYTES = 80
};

typedef struct airsim_lc3_encoder airsim_lc3_encoder;
typedef struct airsim_lc3_decoder airsim_lc3_decoder;

airsim_lc3_encoder *airsim_lc3_encoder_create(void);
airsim_lc3_decoder *airsim_lc3_decoder_create(void);
void airsim_lc3_encoder_destroy(airsim_lc3_encoder *encoder);
void airsim_lc3_decoder_destroy(airsim_lc3_decoder *decoder);

/* One session owns each context; calls on a context must be serial. */
int airsim_lc3_encode(airsim_lc3_encoder *encoder,
                     const uint8_t pcm[AIRSIM_LC3_PCM_BYTES],
                     uint8_t packet[AIRSIM_LC3_PACKET_BYTES]);
/* NULL packet conceals two lost frames. Returns 0 normally, 1 for PLC, -1 on error. */
int airsim_lc3_decode(airsim_lc3_decoder *decoder, const uint8_t *packet,
                     uint8_t pcm[AIRSIM_LC3_PCM_BYTES]);
/* Sequence 0 is a scheduled empty slot and requires NULL packet. Gaps of up
 * to five packets advance PLC without playback; longer gaps reset history. */
int airsim_lc3_decode_packet(airsim_lc3_decoder *decoder, const uint8_t *packet,
                            uint64_t sequence, uint8_t pcm[AIRSIM_LC3_PCM_BYTES]);
int airsim_lc3_delay_samples(void);

#ifdef __cplusplus
}
#endif
#endif
