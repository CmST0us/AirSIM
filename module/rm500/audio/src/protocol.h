#ifndef AIRSIM_PROTOCOL_H
#define AIRSIM_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
#define ASMP_SIZE 360
#define ASMP_PAYLOAD 320
#define ASMP_SAMPLES 160
int asmp_uuid(const char *, uint8_t[16]);
void asmp_header(uint8_t[ASMP_SIZE], const uint8_t[16], uint8_t, uint64_t);
int asmp_check(const uint8_t[ASMP_SIZE], const uint8_t[16], uint8_t, uint64_t *,
               uint64_t *);
uint64_t asmp_now_ms(void);
int asmp_write(int, const void *, size_t, int);
int asmp_recover_budget(uint64_t times[3], unsigned *count, uint64_t now);
#endif
