/* Controller-only, bounded diagnostic. No PCM bytes leave worker memory. */
#include "cadence-options.h"
#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <tinyalsa/pcm.h>
#include <unistd.h>

/* Fixed upstream pcm.c defines this symbol but v2.0.0 pcm.h omits it. */
extern int pcm_state(struct pcm *pcm);

static atomic_int stop;
static pthread_mutex_t output_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t began;
struct direction {
  struct pcm *pcm;
  unsigned device, flags, records, recoveries, snapshots, rate, frames,
      progress_bucket;
  uint64_t operations;
  const char *last_op;
  int last_rc, last_errno;
  uint64_t samples;
  int failed, sample_limit;
  const char *name, *proc;
};
static uint64_t now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
static int running(struct direction *d) {
  return !atomic_load(&stop) && now_ms() - began < 2000 && !d->sample_limit;
}
static void snapshot(struct direction *d, unsigned phase);
static void string_json(const char *s, size_t n) {
  putchar('"');
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '"' || c == '\\') {
      putchar('\\');
      putchar(c);
    } else if (c < 32 || c >= 127)
      printf("\\u%04x", c);
    else
      putchar(c);
  }
  putchar('"');
}
/* rc/errno/time are saved by the caller before this safe patched state query.
 */
static void record(struct direction *d, const char *op, int rc, int saved_errno,
                   unsigned frames, uint64_t at) {
  d->operations++;
  d->last_op = op;
  d->last_rc = rc;
  d->last_errno = saved_errno;
  if (d->records >= 32)
    return;
  errno = 0;
  int state = d->pcm && pcm_is_ready(d->pcm) ? pcm_state(d->pcm) : -1;
  int state_errno = errno;
  d->records++;
  pthread_mutex_lock(&output_lock);
  printf("{\"type\":\"operation\",\"direction\":\"%s\",\"index\":%u,"
         "\"ms\":%" PRIu64 ",\"op\":\"%s\",\"state\":%d,\"state_errno\":%d,"
         "\"rc\":%d,\"errno\":%d,\"requested_frames\":%u,\"successful_"
         "samples\":%u,"
         "\"total_samples\":%" PRIu64 "}\n",
         d->name, d->records, at - began, op, state, state_errno, rc,
         saved_errno, frames, frames && rc > 0 ? (unsigned)rc : 0, d->samples);
  fflush(stdout);
  pthread_mutex_unlock(&output_lock);
  if (d->records == 32)
    snapshot(d, 2);
}
static void snapshot(struct direction *d, unsigned phase) {
  if (d->snapshots & phase)
    return;
  d->snapshots |= phase;
  const char *phase_name = phase == 1   ? "first_failure"
                           : phase == 2 ? "first32"
                                        : "end";
  pthread_mutex_lock(&output_lock);
  printf("{\"type\":\"snapshot_context\",\"direction\":\"%s\",\"phase\":\"%s\","
         "\"ms\":%" PRIu64 ",\"total_samples\":%" PRIu64
         ",\"operations\":%" PRIu64 ",\"last_op\":\"%s\",\"last_rc\":%d,\"last_"
         "errno\":%d,\"sample_limit\":%s}\n",
         d->name, phase_name, now_ms() - began, d->samples, d->operations,
         d->last_op ? d->last_op : "none", d->last_rc, d->last_errno,
         d->sample_limit ? "true" : "false");
  fflush(stdout);
  pthread_mutex_unlock(&output_lock);
  const char *names[] = {"status", "hw_params", "sw_params"};
  for (unsigned i = 0; i < 3; i++) {
    char path[128], raw[4096];
    snprintf(path, sizeof(path), "%s/%s", d->proc, names[i]);
    errno = 0;
    FILE *f = fopen(path, "r");
    int e = errno, readable = 0, truncated = 0;
    size_t n = 0;
    if (f) {
      n = fread(raw, 1, sizeof(raw), f);
      e = errno;
      readable = !ferror(f);
      if (n == sizeof(raw))
        truncated = fgetc(f) != EOF;
      fclose(f);
    }
    pthread_mutex_lock(&output_lock);
    printf("{\"type\":\"proc_snapshot\",\"direction\":\"%s\",\"ms\":%" PRIu64
           ",\"phase\":\"%s\",\"file\":\"%s\",\"readable\":%s,\"errno\":%d,"
           "\"truncated\":%s,"
           "\"text\":",
           d->name, now_ms() - began, phase_name, names[i],
           readable ? "true" : "false", e, truncated ? "true" : "false");
    string_json(raw, n);
    puts("}");
    fflush(stdout);
    pthread_mutex_unlock(&output_lock);
  }
}
static int prepare_only(struct direction *d) {
  if (!running(d))
    return -1;
  errno = 0;
  int rc = pcm_prepare(d->pcm);
  int e = errno;
  uint64_t at = now_ms();
  record(d, "prepare", rc, e, 0, at);
  if (rc < 0) {
    d->failed = 1;
    snapshot(d, 1);
    return -1;
  }
  return 0;
}
static int start_capture(struct direction *d) {
  if (!running(d))
    return -1;
  errno = 0;
  int rc = pcm_start(d->pcm);
  int e = errno;
  uint64_t at = now_ms();
  record(d, "start", rc, e, 0, at);
  if (rc < 0) {
    d->failed = 1;
    snapshot(d, 1);
    return -1;
  }
  return 0;
}
static int prepare(struct direction *d) {
  if (prepare_only(d))
    return -1;
  return d->flags == PCM_IN ? start_capture(d) : 0;
}
static void progress(struct direction *d) {
  uint64_t elapsed = now_ms() - began;
  unsigned bucket = elapsed / 500 > 4 ? 4 : (unsigned)(elapsed / 500);
  if (bucket == 0 || bucket <= d->progress_bucket)
    return;
  d->progress_bucket = bucket;
  pthread_mutex_lock(&output_lock);
  printf("{\"type\":\"progress\",\"direction\":\"%s\",\"elapsed_ms\":%" PRIu64
         ",\"samples\":%" PRIu64 ",\"requested_rate\":%u}\n",
         d->name, elapsed, d->samples, d->rate);
  fflush(stdout);
  pthread_mutex_unlock(&output_lock);
}
static void *worker(void *arg) {
  struct direction *d = arg;
  uint8_t data[640] = {0};
  while (running(d)) {
    progress(d);
    errno = 0;
    int rc = d->flags == PCM_IN ? pcm_readi(d->pcm, data, d->frames)
                                : pcm_writei(d->pcm, data, d->frames);
    int e = errno;
    uint64_t at = now_ms();
    if (rc > 0)
      d->samples += (unsigned)rc;
    /* Capture is discarded immediately, including partial/failed reads. */
    if (d->flags == PCM_IN) {
      volatile uint8_t *wipe = data;
      for (unsigned i = 0; i < 320; i++)
        wipe[i] = 0;
    }
    record(d, d->flags == PCM_IN ? "readi" : "writei", rc, e, d->frames, at);
    if (d->samples > 64000) {
      d->sample_limit = 1;
      d->failed = 1;
      snapshot(d, 1);
      break;
    }
    if (rc > 0 && (unsigned)rc <= d->frames)
      continue;
    if (rc < 0 && e == EINTR)
      continue;
    if (rc == 0 || (rc < 0 && e == EAGAIN)) {
      if (!running(d))
        break;
      struct pollfd fd = {pcm_get_poll_fd(d->pcm),
                          d->flags == PCM_IN ? POLLIN : POLLOUT, 0};
      errno = 0;
      int pr = poll(&fd, 1, 10);
      int pe = errno;
      at = now_ms();
      record(d, "poll", pr, pe, 0, at);
      if ((pr < 0 && pe != EINTR) || (fd.revents & POLLNVAL)) {
        d->failed = 1;
        snapshot(d, 1);
        break;
      }
      continue;
    }
    d->failed = 1;
    snapshot(
        d, 1); /* Preserve the first failure before any recovery changes it. */
    if (rc < 0 && e == EPIPE && d->recoveries == 0 && running(d)) {
      d->recoveries++;
      if (!prepare(d))
        continue;
    }
    break;
  }
  progress(d);
  return NULL;
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--version")) {
    puts("pcm-cadence-probe 3 tinyalsa-1c5fb68+pcm-state-a36d521");
    return 0;
  }
  unsigned playback_rate;
  if (cadence_rate(argc, argv, &playback_rate))
    return 2;
  signal(SIGALRM, SIG_DFL);
  alarm(3);
  began = now_ms();
  struct direction dirs[] = {{.device = 9,
                              .flags = PCM_IN,
                              .rate = 8000,
                              .frames = 160,
                              .name = "capture",
                              .proc = "/proc/asound/card0/pcm9c/sub0"},
                             {.device = 55,
                              .flags = PCM_OUT,
                              .rate = playback_rate,
                              .frames = playback_rate / 50,
                              .name = "playback",
                              .proc = "/proc/asound/card0/pcm55p/sub0"}};
  struct pcm_config cfg = {.channels = 1,
                           .rate = 8000,
                           .period_size = 320,
                           .period_count = 2,
                           .format = PCM_FORMAT_S16_LE,
                           .start_threshold = 320,
                           .stop_threshold = 640,
                           .avail_min = 320};
  int ready = 1;
  for (unsigned i = 0; i < 2; i++) {
    cfg.rate = dirs[i].rate;
    cfg.start_threshold = dirs[i].flags == PCM_IN ? 320 : 640;
    errno = 0;
    dirs[i].pcm = pcm_open(0, dirs[i].device,
                           dirs[i].flags | PCM_NONBLOCK | PCM_NORESTART, &cfg);
    int e = errno;
    uint64_t at = now_ms();
    int ok = dirs[i].pcm && pcm_is_ready(dirs[i].pcm);
    record(&dirs[i], "open_ready", ok ? 0 : -1, e, 0, at);
    if (!ok) {
      ready = 0;
      dirs[i].failed = 1;
      snapshot(&dirs[i], 1);
    }
  }
  if (ready && (prepare_only(&dirs[0]) || prepare_only(&dirs[1]) ||
                start_capture(&dirs[0])))
    ready = 0;
  pthread_t threads[2];
  unsigned count = 0;
  if (ready) {
    for (; count < 2; count++) {
      int rc = pthread_create(&threads[count], NULL, worker, &dirs[count]);
      if (rc) {
        dirs[count].failed = 1;
        record(&dirs[count], "pthread_create", rc, 0, 0, now_ms());
        snapshot(&dirs[count], 1);
        break;
      }
    }
    while (count == 2 && now_ms() - began < 2000) {
      struct timespec delay = {0, 10000000};
      nanosleep(&delay, NULL);
    }
  }
  atomic_store(&stop, 1);
  for (unsigned i = 0; i < count; i++)
    pthread_join(threads[i], NULL);
  int failed = !ready || count != 2;
  for (unsigned i = 0; i < 2; i++)
    snapshot(&dirs[i], 4);
  for (unsigned i = 0; i < 2; i++) {
    int rc = 0, e = 0;
    if (dirs[i].pcm) {
      errno = 0;
      rc = pcm_close(dirs[i].pcm);
      e = errno;
    }
    printf("{\"type\":\"summary\",\"direction\":\"%s\",\"ms\":%" PRIu64
           ",\"recorded_operations\":%u,\"operations\":%" PRIu64
           ",\"total_samples\":%" PRIu64
           ",\"recoveries\":%u,\"observed_failure\":%s,\"sample_limit\":%s,"
           "\"close_rc\":%d,\"close_"
           "errno\":%d}\n",
           dirs[i].name, now_ms() - began, dirs[i].records, dirs[i].operations,
           dirs[i].samples, dirs[i].recoveries,
           dirs[i].failed ? "true" : "false",
           dirs[i].sample_limit ? "true" : "false", rc, e);
    failed |= dirs[i].failed || rc != 0;
    fflush(stdout);
  }
  return failed ? 1 : 0;
}
