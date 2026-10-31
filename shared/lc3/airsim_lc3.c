#include "airsim_lc3.h"
#include "lc3.h"
#include <stdlib.h>

struct airsim_lc3_encoder {
    lc3_encoder_t codec;
    unsigned char memory[];
};
struct airsim_lc3_decoder {
    lc3_decoder_t codec;
    uint64_t last_sequence;
    uint64_t concealed_slots;
    unsigned char memory[];
};

airsim_lc3_encoder *airsim_lc3_encoder_create(void) {
    unsigned size = lc3_encoder_size(AIRSIM_LC3_FRAME_US, AIRSIM_LC3_SAMPLE_RATE);
    airsim_lc3_encoder *ctx = calloc(1, sizeof(*ctx) + size);
    if (!ctx) return NULL;
    ctx->codec = lc3_setup_encoder(AIRSIM_LC3_FRAME_US, AIRSIM_LC3_SAMPLE_RATE, 0, ctx->memory);
    if (!ctx->codec) { free(ctx); return NULL; }
    return ctx;
}

airsim_lc3_decoder *airsim_lc3_decoder_create(void) {
    unsigned size = lc3_decoder_size(AIRSIM_LC3_FRAME_US, AIRSIM_LC3_SAMPLE_RATE);
    airsim_lc3_decoder *ctx = calloc(1, sizeof(*ctx) + size);
    if (!ctx) return NULL;
    ctx->codec = lc3_setup_decoder(AIRSIM_LC3_FRAME_US, AIRSIM_LC3_SAMPLE_RATE, 0, ctx->memory);
    if (!ctx->codec) { free(ctx); return NULL; }
    return ctx;
}

void airsim_lc3_encoder_destroy(airsim_lc3_encoder *ctx) { free(ctx); }
void airsim_lc3_decoder_destroy(airsim_lc3_decoder *ctx) { free(ctx); }

int airsim_lc3_encode(airsim_lc3_encoder *ctx, const uint8_t pcm[AIRSIM_LC3_PCM_BYTES],
                     uint8_t packet[AIRSIM_LC3_PACKET_BYTES]) {
    if (!ctx || !pcm || !packet) return -1;
    int16_t samples[AIRSIM_LC3_PACKET_SAMPLES];
    for (int i = 0; i < AIRSIM_LC3_PACKET_SAMPLES; i++)
        samples[i] = (int16_t)((uint16_t)pcm[2*i] | (uint16_t)pcm[2*i+1] << 8);
    for (int frame = 0; frame < 2; frame++)
        if (lc3_encode(ctx->codec, LC3_PCM_FORMAT_S16, samples + frame * AIRSIM_LC3_FRAME_SAMPLES, 1,
                       AIRSIM_LC3_FRAME_BYTES, packet + frame * AIRSIM_LC3_FRAME_BYTES) < 0) return -1;
    return 0;
}

int airsim_lc3_decode(airsim_lc3_decoder *ctx, const uint8_t *packet,
                     uint8_t pcm[AIRSIM_LC3_PCM_BYTES]) {
    if (!ctx || !pcm) return -1;
    int16_t samples[AIRSIM_LC3_PACKET_SAMPLES];
    int concealed = 0;
    for (int frame = 0; frame < 2; frame++) {
        int result = lc3_decode(ctx->codec, packet ? packet + frame * AIRSIM_LC3_FRAME_BYTES : NULL,
                                AIRSIM_LC3_FRAME_BYTES, LC3_PCM_FORMAT_S16, samples + frame * AIRSIM_LC3_FRAME_SAMPLES, 1);
        if (result < 0) return -1;
        concealed |= result;
    }
    for (int i = 0; i < AIRSIM_LC3_PACKET_SAMPLES; i++) {
        uint16_t value = (uint16_t)samples[i];
        pcm[2*i] = (uint8_t)value;
        pcm[2*i+1] = (uint8_t)(value >> 8);
    }
    return concealed;
}

int airsim_lc3_delay_samples(void) {
    return lc3_delay_samples(AIRSIM_LC3_FRAME_US, AIRSIM_LC3_SAMPLE_RATE);
}

int airsim_lc3_decode_packet(airsim_lc3_decoder *ctx, const uint8_t *packet,
                            uint64_t sequence, uint8_t pcm[AIRSIM_LC3_PCM_BYTES]) {
    if (!ctx || !pcm) return -1;
    if (sequence == 0) {
        if (packet) return -1;
        int result = airsim_lc3_decode(ctx, NULL, pcm);
        if (result >= 0) ctx->concealed_slots++;
        return result;
    }
    if (sequence <= ctx->last_sequence) return -1;
    uint64_t missing = ctx->last_sequence ? sequence - ctx->last_sequence - 1 : 0;
    missing = missing > ctx->concealed_slots ? missing - ctx->concealed_slots : 0;
    ctx->concealed_slots = 0;
    if (missing > 5) {
        ctx->codec = lc3_setup_decoder(AIRSIM_LC3_FRAME_US, AIRSIM_LC3_SAMPLE_RATE, 0, ctx->memory);
        if (!ctx->codec) return -1;
    } else {
        uint8_t discarded[AIRSIM_LC3_PCM_BYTES];
        for (uint64_t n = 0; n < missing; n++)
            if (airsim_lc3_decode(ctx, NULL, discarded) < 0) return -1;
    }
    ctx->last_sequence = sequence;
    return airsim_lc3_decode(ctx, packet, pcm);
}
