#include "protocol.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>
static int fake_write(int, const void *, size_t, int);
static int fake_shutdown(int, int);
#define asmp_write fake_write
#define shutdown fake_shutdown
#ifndef ESTRPIPE
#define ESTRPIPE 86
#endif
static uint64_t fake_now;
static uint64_t fake_clock(void) { return fake_now; }
#define asmp_now_ms fake_clock
#define main audiod_entry_not_run
#include "../src/audiod.c"
#undef main
#undef asmp_now_ms
#undef asmp_write
#undef shutdown

static char events[64];
static unsigned event_count;
static int prepare_error, start_error, transfer_errno, transfer_limit;
static unsigned prepare_calls, prepare_fail_call;
static struct pcm *prepared[2], *started_pcm;
static void event(char c) {
  assert(event_count < sizeof(events));
  events[event_count++] = c;
}
static int fake_write(int fd, const void *data, size_t n, int timeout) {
  assert(fd == 3 && n > 4 && timeout == 100);
  char json[2049];
  assert(n - 4 < sizeof(json));
  memcpy(json, (const char *)data + 4, n - 4);
  json[n - 4] = 0;
  if (strstr(json, "\"type\":\"stats\""))
    event('T');
  else {
    assert(strstr(json, "\"type\":\"error\""));
    event('E');
  }
  return 0;
}
static int fake_shutdown(int fd, int how) {
  assert(fd == 4 && how == SHUT_RDWR);
  event('X');
  return 0;
}
int pcm_prepare(struct pcm *p) {
  if (prepare_calls < 2)
    prepared[prepare_calls] = p;
  prepare_calls++;
  event('P');
  return prepare_error || (prepare_fail_call == prepare_calls) ? -1 : 0;
}
int pcm_start(struct pcm *p) {
  started_pcm = p;
  event('S');
  return start_error;
}
static int io(unsigned n, char direction) {
  event(direction);
  if (transfer_errno) {
    errno = transfer_errno;
    return -1;
  }
  return transfer_limit && n > (unsigned)transfer_limit ? transfer_limit
                                                        : (int)n;
}
int pcm_readi(struct pcm *p, void *b, unsigned n) {
  (void)p;
  (void)b;
  return io(n, 'R');
}
int pcm_writei(struct pcm *p, const void *b, unsigned n) {
  (void)p;
  (void)b;
  return io(n, 'W');
}
int pcm_get_poll_fd(struct pcm *p) {
  (void)p;
  assert(!"unexpected poll");
  return -1;
}
struct pcm *pcm_open(unsigned c, unsigned d, unsigned f,
                     const struct pcm_config *cfg) {
  (void)c;
  (void)d;
  (void)f;
  (void)cfg;
  assert(!"real open forbidden");
  return NULL;
}
int pcm_close(struct pcm *p) {
  (void)p;
  assert(!"unexpected close");
  return 0;
}
int pcm_is_ready(const struct pcm *p) {
  (void)p;
  return 0;
}
static struct pcm_config test_config;
const struct pcm_config *pcm_get_config(const struct pcm *p) {
  (void)p;
  return &test_config;
}
unsigned pcm_get_buffer_size(const struct pcm *p) {
  (void)p;
  return 640;
}
static void reset(void) {
  interrupted = 0;
  atomic_store(&stopping, 0);
  atomic_store(&failure, 0);
  memset(&capture_stats, 0, sizeof(capture_stats));
  memset(&playback_stats, 0, sizeof(playback_stats));
  atomic_store(&silence, 0);
  event_count = 0;
  prepare_calls = prepare_fail_call = 0;
  prepare_error = start_error = transfer_errno = transfer_limit = 0;
  started = fake_now = 1000;
  playback_rate = 8000;
  playback_previous = 0;
}
static void order(const char *s) {
  assert(event_count == strlen(s));
  assert(!memcmp(events, s, event_count));
}
int main(void) {
  char path[] = "/tmp/airsim-hw-test-XXXXXX";
  int fd = mkstemp(path);
  assert(fd >= 0);
  const char *hw = "format: S16_LE\nchannels: 1\nrate: 8000\nperiod_size: "
                   "320\nbuffer_size: 640\n";
  assert(write(fd, hw, strlen(hw)) == (ssize_t)strlen(hw));
  close(fd);
  test_config = (struct pcm_config){.channels = 1,
                                    .rate = 8000,
                                    .format = PCM_FORMAT_S16_LE,
                                    .period_size = 320,
                                    .period_count = 2,
                                    .start_threshold = 320,
                                    .stop_threshold = 640,
                                    .avail_min = 320};
  struct actual_config actual;
  assert(hw_verify(path, NULL, &actual, 320, 8000) == 0);
  assert(hw_verify(path, NULL, &actual, 640, 8000) == -1);
  test_config.start_threshold = 640;
  assert(hw_verify(path, NULL, &actual, 640, 8000) == 0);
  assert(hw_verify(path, NULL, &actual, 320, 8000) == -1);
  FILE *hf = fopen(path, "w");
  assert(hf);
  assert(fputs("format: S16_LE\nchannels: 1\nrate: 16000\nperiod_size: "
               "320\nbuffer_size: 640\n",
               hf) >= 0);
  fclose(hf);
  test_config.rate = 16000;
  assert(hw_verify(path, NULL, &actual, 640, 16000) == 0);
  assert(hw_verify(path, NULL, &actual, 640, 8000) == -1);
  unlink(path);

  reset();
  capture = (struct pcm *)(uintptr_t)1;
  playback = (struct pcm *)(uintptr_t)2;
  assert(prepare_initial() == 0);
  order("PPS");
  assert(prepared[0] == capture && prepared[1] == playback &&
         started_pcm == capture);
  for (unsigned i = 1; i <= 2; i++) {
    reset();
    prepare_fail_call = i;
    assert(prepare_initial() == -1 && atomic_load(&failure) == 4);
    order(i == 1 ? "P" : "PP");
  }
  reset();
  start_error = -1;
  assert(prepare_initial() == -1 && atomic_load(&failure) == 4);
  order("PPS");
  /* Workers must not repeat the main-thread initialization. */
  reset();
  transfer_errno = EIO;
  capture_worker(NULL);
  order("R");
  reset();
  transfer_errno = EIO;
  playback_worker(NULL);
  order("W");
  reset();
  fail(6);
  finish_media(1);
  alarm(0);
  order("TEX");
  reset();
  fail(4);
  finish_media(0);
  alarm(0);
  order("EX");
  reset();
  finish_media(1);
  alarm(0);
  order("TX");
  uint8_t data[640] = {0};
  for (int input = 0; input <= 1; input++) {
    for (int suspended = 0; suspended <= 1; suspended++) {
      reset();
      uint64_t recovery[3] = {0};
      unsigned count = 0;
      struct counters *stats = input ? &capture_stats : &playback_stats;
      transfer_errno = suspended ? ESTRPIPE : EPIPE;
      assert(transfer(NULL, data, input, stats, !input, recovery, &count) == 1);
      order(input ? "RPS" : "WP");
      assert(atomic_load(&stats->xruns) == 1);
      assert(atomic_load(&stats->samples) == 0);
      transfer_errno = 0;
      assert(transfer(NULL, data, input, stats, !input, recovery, &count) == 0);
      assert(atomic_load(&stats->samples) == 160);
      /* Recovery failures terminate, never continue reading/writing. */
      prepare_error = -1;
      transfer_errno = EPIPE;
      assert(transfer(NULL, data, input, stats, !input, recovery, &count) ==
             -1);
      assert(atomic_load(&failure) == 4);
    }
    reset();
    uint64_t recovery[3] = {0};
    unsigned count = 0;
    struct counters *stats = input ? &capture_stats : &playback_stats;
    transfer_limit = 80; /* Partial positive transfers count fully. */
    for (int i = 0; i < 8; i++)
      assert(transfer(NULL, data, input, stats, !input, recovery, &count) == 0);
    assert(atomic_load(&stats->samples) == 1280); /* Exact bound accepted. */
    assert(transfer(NULL, data, input, stats, !input, recovery, &count) == -1);
    assert(atomic_load(&stats->samples) ==
           1360); /* Offending samples retained. */
    assert(atomic_load(&failure) == 4 && stopped());
    if (!input)
      assert(atomic_load(&silence) == 1360);
    reset();
    count = 0;
    stats = input ? &capture_stats : &playback_stats;
    /* A real 8kHz progression passes beyond the initial allowance. */
    for (int i = 0; i < 20; i++) {
      fake_now += 20;
      assert(transfer(NULL, data, input, stats, !input, recovery, &count) == 0);
    }
    assert(atomic_load(&stats->samples) == 3200 && !stopped());
  }
  reset();
  uint64_t recovery[3] = {0};
  unsigned count = 0;
  transfer_errno = EPIPE;
  start_error = -1;
  assert(transfer(NULL, data, 1, &capture_stats, 0, recovery, &count) == -1);
  order("RPS");
  assert(atomic_load(&failure) == 4);
  reset();
  playback_rate = 16000;
  fake_now += 100;
  count = 0;
  playback_previous = 1234;
  assert(transfer(NULL, data, 0, &playback_stats, 0, recovery, &count) == 0);
  assert(atomic_load(&playback_stats.samples) == 320);
  assert(transfer(NULL, data, 1, &capture_stats, 0, recovery, &count) == 0);
  assert(atomic_load(&capture_stats.samples) == 160);
  transfer_errno = EPIPE;
  assert(transfer(NULL, data, 0, &playback_stats, 0, recovery, &count) == 1);
  assert(playback_previous == 0);
  reset();
  playback_rate = 16000;
  count = 0;
  fake_now += 100;
  for (int i = 0; i < 9; i++)
    assert(transfer(NULL, data, 0, &playback_stats, 0, recovery, &count) == 0);
  assert(atomic_load(&playback_stats.samples) == 2880);
  assert(transfer(NULL, data, 0, &playback_stats, 0, recovery, &count) == -1);
  assert(atomic_load(&failure) == 4 &&
         atomic_load(&playback_stats.samples) == 3200);
  puts("PCM worker startup, recovery, partial transfer and clock guard tests "
       "passed");
}
