#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include "airsim_lc3.h"
#include <stdlib.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "codec test failed: %s\n", #condition); exit(1); \
} } while (0)

static const int16_t tone[20] = {
    0, 3090, 5878, 8090, 9511, 10000, 9511, 8090, 5878, 3090,
    0, -3090, -5878, -8090, -9511, -10000, -9511, -8090, -5878, -3090
};
static void input(uint8_t *pcm, int packet) {
    for (int i = 0; i < AIRSIM_LC3_PACKET_SAMPLES; i++) {
        uint16_t sample = (uint16_t)tone[(packet * AIRSIM_LC3_PACKET_SAMPLES + i) % 20];
        pcm[2*i] = (uint8_t)sample;
        pcm[2*i+1] = (uint8_t)(sample >> 8);
    }
}
static int16_t sample(const uint8_t *pcm, int i) {
    return (int16_t)((uint16_t)pcm[2*i] | (uint16_t)pcm[2*i+1] << 8);
}
static double milliseconds(void) {
    struct timespec t;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (double)t.tv_sec * 1000 + (double)t.tv_nsec / 1000000;
}
static void dropped_packets(void) {
    airsim_lc3_encoder *encoder = airsim_lc3_encoder_create();
    airsim_lc3_decoder *timed = airsim_lc3_decoder_create();
    airsim_lc3_decoder *reference = airsim_lc3_decoder_create();
    CHECK(encoder && timed && reference);
    uint8_t pcm[AIRSIM_LC3_PCM_BYTES], packets[12][80], actual[AIRSIM_LC3_PCM_BYTES], expected[AIRSIM_LC3_PCM_BYTES];
    for (int i = 0; i < 12; i++) {
        input(pcm, i);
        CHECK(airsim_lc3_encode(encoder, pcm, packets[i]) == 0);
    }
    for (int i = 0; i < 3; i++) {
        CHECK(airsim_lc3_decode_packet(timed, packets[i], i + 1, actual) == 0);
        CHECK(airsim_lc3_decode(reference, packets[i], expected) == 0);
    }
    CHECK(airsim_lc3_decode(reference, NULL, expected) == 1);
    CHECK(airsim_lc3_decode(reference, NULL, expected) == 1);
    CHECK(airsim_lc3_decode(reference, packets[5], expected) == 0);
    CHECK(airsim_lc3_decode_packet(timed, packets[5], 6, actual) == 0);
    CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
    CHECK(airsim_lc3_decode_packet(timed, NULL, 0, actual) == 1);
    CHECK(airsim_lc3_decode(reference, NULL, expected) == 1);
    CHECK(airsim_lc3_decode(reference, NULL, expected) == 1);
    CHECK(airsim_lc3_decode(reference, packets[8], expected) == 0);
    CHECK(airsim_lc3_decode_packet(timed, packets[8], 9, actual) == 0);
    CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
    CHECK(airsim_lc3_decode_packet(timed, packets[8], 9, actual) == -1);
    airsim_lc3_decoder_destroy(reference);
    reference = airsim_lc3_decoder_create();
    CHECK(reference);
    CHECK(airsim_lc3_decode(reference, packets[11], expected) == 0);
    CHECK(airsim_lc3_decode_packet(timed, packets[11], 100, actual) == 0);
    CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
    airsim_lc3_decoder_destroy(timed);
    airsim_lc3_decoder_destroy(reference);
    airsim_lc3_encoder_destroy(encoder);
}
int main(int argc, char **argv) {
    int vector = argc == 2 && strcmp(argv[1], "--vector") == 0;
    airsim_lc3_encoder *encoder = airsim_lc3_encoder_create();
    airsim_lc3_decoder *decoder = airsim_lc3_decoder_create();
    CHECK(encoder && decoder);
    uint8_t pcm[AIRSIM_LC3_PCM_BYTES], encoded[80], decoded[AIRSIM_LC3_PCM_BYTES], first[80];
    int delay = airsim_lc3_delay_samples();
    CHECK(delay >= 0 && delay < AIRSIM_LC3_PACKET_SAMPLES);
    if (vector) printf("{\"sample_rate\":%d,\"codec_frame_us\":10000,\"codec_frame_bytes\":40,\"algorithmic_delay_samples\":%d,\"packets\":[", AIRSIM_LC3_SAMPLE_RATE, delay);
    double signal = 0, error = 0, max_ms = 0, start = milliseconds();
    int packets = vector ? 16 : 1000;
    for (int p = 0; p < packets; p++) {
        input(pcm, p);
        double before = milliseconds();
        CHECK(airsim_lc3_encode(encoder, pcm, encoded) == 0);
        CHECK(airsim_lc3_decode(decoder, encoded, decoded) == 0);
        double cost = milliseconds() - before;
        if (cost > max_ms) max_ms = cost;
        if (p == 0) memcpy(first, encoded, sizeof(first));
        if (vector) {
            printf("%s\"", p ? "," : "");
            for (int j = 0; j < 80; j++) printf("%02x", encoded[j]);
            printf("\"");
        }
        if (p > 4) for (int i = 0; i < AIRSIM_LC3_PACKET_SAMPLES; i++) {
            double expected = tone[(p * AIRSIM_LC3_PACKET_SAMPLES + i - delay) % 20];
            double delta = sample(decoded, i) - expected;
            signal += expected * expected;
            error += delta * delta;
        }
    }
    double elapsed = milliseconds() - start;
    double snr = 10 * log10(signal / error);
    CHECK(snr > 15);
    CHECK(airsim_lc3_decode(decoder, NULL, decoded) == 1);
    CHECK(airsim_lc3_decode(decoder, NULL, decoded) == 1);
    input(pcm, 0);
    CHECK(airsim_lc3_encode(encoder, pcm, encoded) == 0);
    CHECK(airsim_lc3_decode(decoder, encoded, decoded) >= 0);
    airsim_lc3_encoder_destroy(encoder);
    dropped_packets();
    airsim_lc3_decoder_destroy(decoder);
    encoder = airsim_lc3_encoder_create();
    CHECK(encoder);
    CHECK(airsim_lc3_encode(encoder, pcm, encoded) == 0);
    CHECK(memcmp(first, encoded, sizeof(first)) == 0);
    CHECK(airsim_lc3_encode(NULL, pcm, encoded) == -1);
    CHECK(airsim_lc3_decode(NULL, encoded, pcm) == -1);
    airsim_lc3_encoder_destroy(encoder);
    if (vector) puts("]}");
    else {
        struct rusage usage;
        CHECK(getrusage(RUSAGE_SELF, &usage) == 0);
        long rss = usage.ru_maxrss;
#ifdef __APPLE__
        rss /= 1024;
#endif
        printf("LC3 packets=%d payload_bytes=80 delay_samples=%d mean_encode_decode_ms=%.3f max_encode_decode_ms=%.3f max_rss_kib=%ld tone_snr_db=%.2f PLC=passed reset=passed\n", packets, delay, elapsed / packets, max_ms, rss, snr);
    }
    return 0;
}
