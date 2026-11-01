#ifndef AIRSIM_PROTOCOL_H
#define AIRSIM_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
/* ASMP v3: a 40-byte header followed by one Opus packet of the stated length. */
#define ASMP_HEADER 40
#define ASMP_MAX_PAYLOAD 1275
#define ASMP_MAX_FRAME (ASMP_HEADER + ASMP_MAX_PAYLOAD)
enum { ASMP_OPUS = 0, ASMP_ERASURE = 1, ASMP_FEC = 2 };
int asmp_uuid(const char *, uint8_t[16]);
void asmp_header(uint8_t[ASMP_HEADER], const uint8_t[16], uint8_t, uint64_t, uint32_t,
                 uint32_t);
/* Returns the payload length a valid header announces, or -1. */
int asmp_payload_size(const uint8_t[ASMP_HEADER], const uint8_t[16], uint8_t);
/* Validates a complete frame of n bytes and advances the sequence. */
int asmp_check(const uint8_t *, size_t n, const uint8_t[16], uint8_t, uint64_t *,
               uint64_t *);
uint64_t asmp_now_ms(void);
int asmp_write(int, const void *, size_t, int);
int asmp_recover_budget(uint64_t times[3], unsigned *count, uint64_t now);
#endif
