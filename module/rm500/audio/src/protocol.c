#include "protocol.h"
#include <errno.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static void put(uint8_t *p, uint64_t n, unsigned count) {
  for (unsigned i = 0; i < count; i++) {
    p[i] = (uint8_t)n;
    n >>= 8;
  }
}
static uint64_t get(const uint8_t *p, unsigned count) {
  uint64_t n = 0;
  for (unsigned i = 0; i < count; i++)
    n |= (uint64_t)p[i] << (8 * i);
  return n;
}
static int hex(char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  return -1;
}
int asmp_uuid(const char *s, uint8_t out[16]) {
  if (strlen(s) != 36 || s[14] != '4' ||
      (s[19] != '8' && s[19] != '9' && s[19] != 'a' && s[19] != 'b'))
    return -1;
  unsigned j = 0;
  for (unsigned i = 0; i < 36;) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (s[i++] != '-')
        return -1;
      continue;
    }
    int a = hex(s[i++]), b = hex(s[i++]);
    if (a < 0 || b < 0 || j >= 16)
      return -1;
    out[j++] = (uint8_t)((a << 4) | b);
  }
  return j == 16 ? 0 : -1;
}
void asmp_header(uint8_t f[ASMP_SIZE], const uint8_t id[16], uint8_t dir,
                 uint64_t seq) {
  memset(f, 0, 40);
  memcpy(f, "ASMP", 4);
  f[4] = 1;
  f[5] = dir;
  put(f + 6, 40, 2);
  memcpy(f + 8, id, 16);
  put(f + 24, seq, 8);
  put(f + 32, 320, 4);
}
int asmp_check(const uint8_t f[ASMP_SIZE], const uint8_t id[16], uint8_t dir,
               uint64_t *last, uint64_t *gaps) {
  uint64_t seq = get(f + 24, 8);
  if (memcmp(f, "ASMP", 4) || f[4] != 1 || f[5] != dir || get(f + 6, 2) != 40 ||
      memcmp(f + 8, id, 16) || get(f + 32, 4) != 320 || get(f + 36, 4) ||
      seq == 0 || seq <= *last)
    return -1;
  *gaps += seq - *last - 1;
  *last = seq;
  return 0;
}
uint64_t asmp_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
int asmp_write(int fd, const void *data, size_t size, int timeout) {
  const uint8_t *p = data;
  uint64_t end = asmp_now_ms() + (uint64_t)timeout;
  while (size) {
    uint64_t now = asmp_now_ms();
    if (now >= end)
      return -1;
    struct pollfd f = {fd, POLLOUT, 0};
    int r = poll(&f, 1, (int)(end - now));
    if (r < 0 && errno == EINTR)
      continue;
    if (r <= 0 || f.revents & (POLLERR | POLLHUP | POLLNVAL))
      return -1;
    ssize_t n = send(fd, p, size, 0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
      continue;
    if (n <= 0)
      return -1;
    p += n;
    size -= (size_t)n;
  }
  return 0;
}
int asmp_recover_budget(uint64_t times[3], unsigned *count, uint64_t now) {
  unsigned n = 0;
  for (unsigned i = 0; i < *count; i++)
    if (now - times[i] < 10000)
      times[n++] = times[i];
  if (n >= 3) {
    *count = n;
    return -1;
  }
  times[n++] = now;
  *count = n;
  return 0;
}
