#define _GNU_SOURCE
#include "audio_format.h"
#include "protocol.h"
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <tinyalsa/pcm.h>
#include <unistd.h>

#ifdef AIRSIM_EG25
#include "../../../eg25/audio/route.h"
#define PLATFORM_PROFILE "eg25-qdc507"
#define PCM_ACCESS PCM_MMAP
#define CAPTURE_DEVICE 6
#define PLAYBACK_DEVICE 5
#define VOICE_PARAMS "/proc/asound/card0/pcm4p/sub0/hw_params"
#define CAPTURE_PARAMS "/proc/asound/card0/pcm6c/sub0/hw_params"
#define PLAYBACK_PARAMS "/proc/asound/card0/pcm5p/sub0/hw_params"
#define PERIOD_SIZE 256
#define PERIOD_COUNT 8
#else
#define PLATFORM_PROFILE "rm500u-embedded"
#define PCM_ACCESS 0
#define CAPTURE_DEVICE 9
#define PLAYBACK_DEVICE 55
#define VOICE_PARAMS "/proc/asound/card0/pcm5p/sub0/hw_params"
#define CAPTURE_PARAMS "/proc/asound/card0/pcm9c/sub0/hw_params"
#define PLAYBACK_PARAMS "/proc/asound/card0/pcm55p/sub0/hw_params"
#define PERIOD_SIZE 320
#define PERIOD_COUNT 2
#endif
#define BUFFER_FRAMES (PERIOD_SIZE * PERIOD_COUNT)
#define PLAYBACK_START (2 * PERIOD_SIZE)

/* Two queued frames + receiver, playback and Agent relay working frames = five.
 * No audio is written to stdout, stderr, a log, or a filesystem object. */
#define QUEUE 2
static volatile sig_atomic_t interrupted;
static atomic_int stopping;
static atomic_int failure;
static const char *codes[] = {"",
                              "ipc",
                              "pcm_open",
                              "pcm_config",
                              "pcm_io",
                              "pcm_stalled",
                              "xrun_budget",
                              "frame_invalid",
                              "control_invalid",
                              "ping_timeout",
                              "parent_lost",
                              "thread_start"};
struct counters {
  atomic_uint_fast64_t samples, xruns, progress;
};
static struct counters capture_stats, playback_stats;
static atomic_uint_fast64_t drops, capture_drops, playback_drops, gaps, silence,
    peak;
static pthread_mutex_t qlock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t queue[QUEUE][ASMP_PAYLOAD];
static uint64_t queued_at[QUEUE];
static unsigned qhead, qcount;
static uint8_t session[16];
static uint64_t started;
static struct pcm *capture, *playback;
static unsigned playback_rate = 8000;
static int16_t playback_previous;
static const char *voice_params = VOICE_PARAMS;
static int stopped(void) { return interrupted || atomic_load(&stopping); }
static void fail(int code) {
  int expected = 0;
  atomic_compare_exchange_strong(&failure, &expected, code);
  atomic_store(&stopping, 1);
}
static void on_signal(int sig) {
  (void)sig;
  interrupted = 1;
  alarm(2);
}
static int send_control(const char *json) {
  size_t n = strlen(json);
  if (!n || n > 2048)
    return -1;
  uint8_t frame[2052];
  for (unsigned i = 0; i < 4; i++)
    frame[i] = (uint8_t)(n >> (8 * i));
  memcpy(frame + 4, json, n);
  return asmp_write(3, frame, n + 4, 100);
}
static int socket_valid(int fd) {
  int type = 0;
  socklen_t len = sizeof(type);
  struct sockaddr_un addr;
  len = sizeof(addr);
  if (getsockname(fd, (struct sockaddr *)&addr, &len) ||
      addr.sun_family != AF_UNIX)
    return 0;
  len = sizeof(type);
  return getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) == 0 &&
         type == SOCK_STREAM;
}
struct actual_config {
  unsigned period, count, buffer;
};
static int hw_verify(const char *path, struct pcm *pcm,
                     struct actual_config *out, unsigned start_threshold,
                     unsigned expected_rate) {
  FILE *f = fopen(path, "r");
  if (!f)
    return -1;
  char line[256], fmt[32] = "";
  unsigned channels = 0, rate = 0, period = 0, buffer = 0;
  while (fgets(line, sizeof(line), f)) {
    if (sscanf(line, "format: %31s", fmt) == 1)
      continue;
    if (sscanf(line, "channels: %u", &channels) == 1)
      continue;
    if (sscanf(line, "rate: %u", &rate) == 1)
      continue;
    if (sscanf(line, "period_size: %u", &period) == 1)
      continue;
    (void)sscanf(line, "buffer_size: %u", &buffer);
  }
  fclose(f);
  out->period = period;
  out->buffer = buffer;
  out->count = period && buffer % period == 0 ? buffer / period : 0;
  const struct pcm_config *c = pcm_get_config(pcm);
  return strcmp(fmt, "S16_LE") == 0 && channels == 1 && rate == expected_rate &&
                 period == PERIOD_SIZE && buffer == BUFFER_FRAMES && c &&
                 c->format == PCM_FORMAT_S16_LE && c->channels == 1 &&
                 c->rate == expected_rate && c->period_size == PERIOD_SIZE &&
                 c->period_count == PERIOD_COUNT && out->count == PERIOD_COUNT &&
                 c->start_threshold == start_threshold &&
                 c->stop_threshold == BUFFER_FRAMES && c->avail_min == PERIOD_SIZE &&
                 pcm_get_buffer_size(pcm) == BUFFER_FRAMES
             ? 0
             : -1;
}
/* Used for initial startup and xrun recovery; playback auto-starts on writes.
 */
static int prepare_direction(struct pcm *p, int input) {
  if (pcm_prepare(p) || (input && pcm_start(p))) {
    fail(4);
    return -1;
  }
  return 0;
}
static int prepare_initial(void) {
  if (pcm_prepare(capture) || pcm_prepare(playback) || pcm_start(capture)) {
    fail(4);
    return -1;
  }
  return 0;
}
static int wait_pcm(struct pcm *p, int input) {
  struct pollfd fd = {pcm_get_poll_fd(p), input ? POLLIN : POLLOUT, 0};
  int r = poll(&fd, 1, 10);
  if (r < 0 && errno == EINTR)
    return 0;
  if (r < 0 || fd.revents & POLLNVAL) {
    fail(4);
    return -1;
  } /* POLLERR may represent XRUN: the next transfer obtains its errno. */
  return 0;
}
static int transfer(struct pcm *p, uint8_t *data, int input,
                    struct counters *stats, int zero_fill, uint64_t recovery[3],
                    unsigned *recoveries) {
  unsigned rate = input ? 8000 : playback_rate;
  unsigned frames = rate / 50;
  unsigned offset = 0;
  uint64_t last = asmp_now_ms();
  while (offset < frames && !stopped()) {
    int n = input ? pcm_readi(p, data + offset * 2, frames - offset)
                  : pcm_writei(p, data + offset * 2, frames - offset);
    if (n > 0) {
      if ((unsigned)n > frames - offset) {
        fail(4);
        return -1;
      }
      offset += (unsigned)n;
      uint64_t total =
          atomic_fetch_add(&stats->samples, (unsigned)n) + (unsigned)n;
      if (zero_fill)
        atomic_fetch_add(&silence, (unsigned)n);
      last = asmp_now_ms();
      atomic_store(&stats->progress, last - started);
      if (total > (uint64_t)rate * (last - started) / 1000 + 2 * BUFFER_FRAMES) {
        fail(4);
        return -1;
      }
      continue;
    }
    int e = errno;
    if (n == 0 || e == EAGAIN || e == EINTR) {
      if (asmp_now_ms() - last > 2000) {
        fail(5);
        return -1;
      }
      if (wait_pcm(p, input))
        return -1;
      continue;
    }
    if (e == EPIPE || e == ESTRPIPE) {
      atomic_fetch_add(&stats->xruns, 1);
      if (asmp_recover_budget(recovery, recoveries, asmp_now_ms())) {
        fail(6);
        return -1;
      }
      if (!input)
        playback_previous = 0;
      if (prepare_direction(p, input)) {
        return -1;
      } /* A recovery starts a new whole frame, never splices discontinuous
           samples. */
      return 1;
    }
    fail(4);
    return -1;
  }
  return stopped() ? -1 : 0;
}
static void *capture_worker(void *unused) {
  (void)unused;
  uint64_t seq = 0, recovery[3] = {0};
  unsigned recoveries = 0;
  uint8_t frame[ASMP_SIZE];
  while (!stopped()) {
    int r = transfer(capture, frame + 40, 1, &capture_stats, 0, recovery,
                     &recoveries);
    if (r < 0)
      break;
    if (r > 0) {
      atomic_fetch_add(&capture_drops, 1);
      continue;
    }
    if (++seq == 0) {
      fail(7);
      break;
    }
    asmp_header(frame, session, 2, seq);
    if (asmp_write(4, frame, sizeof(frame), 100)) {
      if (!stopped()) fail(1);
      break;
    }
  }
  return NULL;
}
static void *playback_worker(void *unused) {
  (void)unused;
  uint64_t recovery[3] = {0};
  unsigned recoveries = 0;
  uint8_t data[640];
  while (!stopped()) {
    int zero_fill = 0;
    pthread_mutex_lock(&qlock);
    uint64_t now = asmp_now_ms();
    while (qcount && now - queued_at[qhead] > 100) {
      qhead = (qhead + 1) % QUEUE;
      qcount--;
      atomic_fetch_add(&drops, 1);
    }
    if (qcount) {
      memcpy(data, queue[qhead], ASMP_PAYLOAD);
      qhead = (qhead + 1) % QUEUE;
      qcount--;
    } else {
      memset(data, 0, sizeof(data));
      zero_fill = 1;
    }
    pthread_mutex_unlock(&qlock);
    (void)audio_expand(data, playback_rate, &playback_previous);
    int r = transfer(playback, data, 0, &playback_stats, zero_fill, recovery,
                     &recoveries);
    if (r < 0)
      break;
    if (r > 0)
      atomic_fetch_add(&playback_drops, 1);
  }
  return NULL;
}
static void *input_worker(void *unused) {
  (void)unused;
  uint8_t frame[ASMP_SIZE];
  size_t offset = 0;
  uint64_t since = 0, last = 0, lost = 0;
  while (!stopped()) {
    struct pollfd p = {4, POLLIN, 0};
    int r = poll(&p, 1, 50);
    if (r < 0 && errno == EINTR)
      continue;
    if (r < 0 || p.revents & (POLLERR | POLLNVAL)) {
      fail(1);
      break;
    }
    if (offset && asmp_now_ms() - since >= 100) {
      fail(1);
      break;
    }
    if (r == 0)
      continue;
    ssize_t n = recv(4, frame + offset, sizeof(frame) - offset, 0);
    if (n < 0 && (errno == EAGAIN || errno == EINTR))
      continue;
    if (n <= 0) {
      if (!stopped()) fail(1);
      break;
    }
    if (offset == 0)
      since = asmp_now_ms();
    offset += (size_t)n;
    if (offset < sizeof(frame))
      continue;
    uint64_t before = lost;
    if (asmp_check(frame, session, 1, &last, &lost)) {
      fail(7);
      break;
    }
    atomic_fetch_add(&gaps, lost - before);
    offset = 0;
    pthread_mutex_lock(&qlock);
    if (qcount == QUEUE) {
      qhead = (qhead + 1) % QUEUE;
      qcount--;
      atomic_fetch_add(&drops, 1);
    }
    unsigned tail = (qhead + qcount) % QUEUE;
    memcpy(queue[tail], frame + 40, ASMP_PAYLOAD);
    queued_at[tail] = asmp_now_ms();
    qcount++;
    if (qcount > atomic_load(&peak))
      atomic_store(&peak, qcount);
    pthread_mutex_unlock(&qlock);
  }
  return NULL;
}
static void send_stats(void) {
  char b[1024];
  snprintf(b, sizeof(b),
           "{\"type\":\"stats\",\"capture_samples\":%" PRIuFAST64
           ",\"playback_samples\":%" PRIuFAST64
           ",\"capture_xruns\":%" PRIuFAST64 ",\"playback_xruns\":%" PRIuFAST64
           ",\"capture_drops\":%" PRIuFAST64 ",\"playback_drops\":%" PRIuFAST64
           ",\"input_drops\":%" PRIuFAST64 ",\"sequence_gaps\":%" PRIuFAST64
           ",\"silence_samples\":%" PRIuFAST64 ",\"queue_peak\":%" PRIuFAST64
           ",\"elapsed_ms\":%" PRIu64 ",\"capture_progress_ms\":%" PRIuFAST64
           ",\"playback_progress_ms\":%" PRIuFAST64 "}",
           atomic_load(&capture_stats.samples),
           atomic_load(&playback_stats.samples),
           atomic_load(&capture_stats.xruns),
           atomic_load(&playback_stats.xruns), atomic_load(&capture_drops),
           atomic_load(&playback_drops), atomic_load(&drops),
           atomic_load(&gaps), atomic_load(&silence), atomic_load(&peak),
           asmp_now_ms() - started, atomic_load(&capture_stats.progress),
           atomic_load(&playback_stats.progress));
  if (send_control(b))
    fail(1);
}
static void finish_media(int ready_sent) {
  alarm(2);
  atomic_store(&stopping, 1);
  if (ready_sent)
    send_stats();
  if (atomic_load(&failure)) {
    char error[100];
    snprintf(error, sizeof(error), "{\"type\":\"error\",\"code\":\"%s\"}",
             codes[atomic_load(&failure)]);
    (void)send_control(error);
  }
  shutdown(4, SHUT_RDWR);
}
int main(int argc, char **argv) {
#ifdef AIRSIM_EG25
  if (argc == 4 && !strcmp(argv[1], "--cleanup") &&
      !strcmp(argv[2], "--profile") && !strcmp(argv[3], PLATFORM_PROFILE))
    return eg25_audio_reset() ? 1 : 0;
#endif
  if (argc == 2 && !strcmp(argv[1], "--version")) {
    puts("airsim-audiod 0.3.0 "
         "tinyalsa-1c5fb68ced57d838f2b7ecd0c00bc1fefc9ab60d");
    return 0;
  }
  if (argc != 5 || strcmp(argv[1], "--session") ||
      asmp_uuid(argv[2], session) || strcmp(argv[3], "--profile") ||
      strcmp(argv[4], PLATFORM_PROFILE)) {
    fputs("airsim-audiod: arguments\n", stderr);
    return 2;
  }
  signal(SIGALRM, SIG_DFL);
  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  pid_t parent = getppid();
  if (parent <= 1 || prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent)
    return 2;
  if (!socket_valid(3) || !socket_valid(4))
    return 2;
  for (int fd = 3; fd <= 4; fd++) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
      return 2;
  }
  pthread_t threads[3];
  unsigned count = 0;
  int ready_sent = 0;
  started = asmp_now_ms();
  struct pcm_config config = {.channels = 1,
                              .rate = 8000,
                              .period_size = PERIOD_SIZE,
                              .period_count = PERIOD_COUNT,
                              .format = PCM_FORMAT_S16_LE,
                              .start_threshold = PERIOD_SIZE,
                              .stop_threshold = BUFFER_FRAMES,
                              .avail_min = PERIOD_SIZE};
#ifdef AIRSIM_EG25
  if (eg25_audio_start()) { fail(2); goto cleanup; }
#endif
  if (audio_voice_rate(voice_params, &playback_rate)) {
    fail(3);
    goto cleanup;
  }
  playback_previous = 0;
  capture = pcm_open(0, CAPTURE_DEVICE, PCM_IN | PCM_ACCESS | PCM_NONBLOCK | PCM_NORESTART, &config);
  if (!capture || !pcm_is_ready(capture)) {
    fail(2);
    goto cleanup;
  }
  config.start_threshold = PLAYBACK_START;
  config.rate = playback_rate;
  playback = pcm_open(0, PLAYBACK_DEVICE, PCM_OUT | PCM_ACCESS | PCM_NONBLOCK | PCM_NORESTART, &config);
  if (!playback || !pcm_is_ready(playback)) {
    fail(2);
    goto cleanup;
  }
  struct actual_config actual_capture = {0}, actual_playback = {0};
  if (hw_verify(CAPTURE_PARAMS, capture,
                &actual_capture, PERIOD_SIZE, 8000) ||
      hw_verify(PLAYBACK_PARAMS, playback,
                &actual_playback, PLAYBACK_START, playback_rate)) {
    fail(3);
    goto cleanup;
  }
  if (prepare_initial())
    goto cleanup;
  if (audio_voice_unchanged(voice_params, playback_rate)) {
    fail(3);
    goto cleanup;
  }
  char ready[512];
  snprintf(ready, sizeof(ready),
           "{\"type\":\"ready\",\"sample_rate\":8000,\"channels\":1,\"sample_"
           "format\":\"s16le\",\"frame_samples\":160,"
           "\"capture\":{\"sample_rate\":8000,\"period_size\":%u,\"period_"
           "count\":%u,\"buffer_"
           "frames\":%u},"
           "\"playback\":{\"sample_rate\":%u,\"period_size\":%u,\"period_"
           "count\":%u,\"buffer_"
           "frames\":%u}}",
           actual_capture.period, actual_capture.count, actual_capture.buffer,
           playback_rate, actual_playback.period, actual_playback.count,
           actual_playback.buffer);
  if (send_control(ready)) {
    fail(1);
    goto cleanup;
  }
  ready_sent = 1;
  void *(*workers[])(void *) = {input_worker, capture_worker, playback_worker};
  for (; count < 3; count++)
    if (pthread_create(&threads[count], NULL, workers[count], NULL)) {
      fail(11);
      break;
    }
  uint8_t control[2052];
  size_t have = 0, need = 4;
  uint64_t ping = asmp_now_ms(), partial = 0, stats = ping;
  while (!stopped()) {
    uint64_t now = asmp_now_ms();
    if (getppid() != parent) {
      fail(10);
      break;
    }
    if (now - ping >= 3000) {
      fail(9);
      break;
    }
    if (have && now - partial >= 100) {
      fail(8);
      break;
    }
    if (now - stats >= 1000) {
      if (audio_voice_unchanged(voice_params, playback_rate)) {
        fail(3);
        break;
      }
      send_stats();
      stats = now;
    }
    struct pollfd p = {3, POLLIN, 0};
    int r = poll(&p, 1, 50);
    if (r < 0 && errno == EINTR)
      continue;
    if (r < 0 || p.revents & (POLLERR | POLLNVAL)) {
      fail(1);
      break;
    }
    if (r == 0)
      continue;
    ssize_t n = recv(3, control + have, need - have, 0);
    if (n < 0 && (errno == EINTR || errno == EAGAIN))
      continue;
    if (n <= 0) {
      atomic_store(&stopping, 1);
      break;
    }
    if (have == 0)
      partial = asmp_now_ms();
    have += (size_t)n;
    if (have == 4 && need == 4) {
      uint32_t size = (uint32_t)control[0] | (uint32_t)control[1] << 8 |
                      (uint32_t)control[2] << 16 | (uint32_t)control[3] << 24;
      if (!size || size > 2048) {
        fail(8);
        break;
      }
      need = 4 + size;
    }
    if (have == need && need > 4) {
      size_t size = need - 4;
      if (size == 13 && !memcmp(control + 4, "{\"op\":\"ping\"}", 13))
        ping = asmp_now_ms();
      else if (size == 13 && !memcmp(control + 4, "{\"op\":\"stop\"}", 13))
        atomic_store(&stopping, 1);
      else
        fail(8);
      have = 0;
      need = 4;
    }
  }
cleanup:
  finish_media(ready_sent);
  for (unsigned i = 0; i < count; i++)
    pthread_join(threads[i], NULL);
  if (playback)
    pcm_close(playback);
  if (capture)
    pcm_close(capture);
#ifdef AIRSIM_EG25
  eg25_audio_stop();
#endif
  close(4);
  close(3);
  return atomic_load(&failure) ? 1 : 0;
}
