#include "protocol.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
int main(void) {
  signal(SIGPIPE, SIG_IGN);
  uint8_t id[16], frame[ASMP_SIZE] = {0};
  assert(!asmp_uuid("12345678-1234-4234-8234-123456789abc", id));
  assert(asmp_uuid("12345678-1234-1234-8234-123456789abc", id));
  assert(!asmp_uuid("12345678-1234-4234-8234-123456789abc", id));
  uint64_t last = 0, gaps = 0;
  asmp_header(frame, id, 1, 1);
  assert(!asmp_check(frame, id, 1, &last, &gaps));
  assert(last == 1 && gaps == 0);
  assert(asmp_check(frame, id, 1, &last, &gaps));
  asmp_header(frame, id, 1, 4);
  assert(!asmp_check(frame, id, 1, &last, &gaps) && gaps == 2);
  for (unsigned i = 0; i < 40; i++) {
    if (i >= 24 && i < 32)
      continue;
    uint8_t bad[ASMP_SIZE];
    memcpy(bad, frame, sizeof(bad));
    bad[i] ^= 0x40;
    last = 0;
    assert(asmp_check(bad, id, 1, &last, &gaps));
  }
  uint64_t times[3] = {0};
  unsigned count = 0;
  assert(!asmp_recover_budget(times, &count, 100));
  assert(!asmp_recover_budget(times, &count, 200));
  assert(!asmp_recover_budget(times, &count, 300));
  assert(asmp_recover_budget(times, &count, 400));
  assert(!asmp_recover_budget(times, &count, 10100));
  int fds[2];
  assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, fds));
  assert(!fcntl(fds[0], F_SETFL, O_NONBLOCK));
  char block[1024] = {0};
  while (send(fds[0], block, sizeof(block), 0) > 0) {
  }
  assert(errno == EAGAIN || errno == EWOULDBLOCK);
  uint64_t start = asmp_now_ms();
  assert(asmp_write(fds[0], frame, sizeof(frame), 100));
  assert(asmp_now_ms() - start < 400);
  close(fds[1]);
  assert(asmp_write(fds[0], frame, sizeof(frame), 100));
  close(fds[0]);
  puts("native framing, identity, sequence, recovery budget, and blocked-write "
       "tests passed");
  return 0;
}
