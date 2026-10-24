/* Minimal host fake of ALSA SYNC_PTR direction semantics. The functions under
 * test are extracted verbatim from the original/strictly patched pcm.c. */
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#define SNDRV_PCM_SYNC_PTR_HWSYNC 1
#define SNDRV_PCM_SYNC_PTR_APPL 2
#define SNDRV_PCM_SYNC_PTR_AVAIL_MIN 4
#define SNDRV_PCM_IOCTL_HWSYNC 1
#define SNDRV_PCM_IOCTL_SYNC_PTR 2
struct sync_ptr {
  unsigned flags, appl_ptr, avail_min;
};
struct status {
  int state;
};
struct ops {
  int (*ioctl)(void *, unsigned, void *);
};
struct pcm {
  struct sync_ptr *sync_ptr;
  struct status *mmap_status;
  struct ops *ops;
  void *data;
  int fd;
};
static unsigned kernel_appl = 320, kernel_avail = 320, calls;
static int ioctl_error;
static int fake_ioctl(void *data, unsigned cmd, void *arg) {
  (void)data;
  assert(cmd == SNDRV_PCM_IOCTL_SYNC_PTR);
  calls++;
  if (ioctl_error) {
    errno = EIO;
    return -1;
  }
  struct sync_ptr *s = arg;
  if (s->flags & SNDRV_PCM_SYNC_PTR_APPL)
    s->appl_ptr = kernel_appl;
  else
    kernel_appl = s->appl_ptr;
  if (s->flags & SNDRV_PCM_SYNC_PTR_AVAIL_MIN)
    s->avail_min = kernel_avail;
  else
    kernel_avail = s->avail_min;
  return 0;
}
static int ioctl(int fd, unsigned cmd) {
  (void)fd;
  (void)cmd;
  assert(0);
  return -1;
}
static void oops(struct pcm *p, int e, const char *s) {
  (void)p;
  (void)e;
  (void)s;
}
#include "state-functions.inc"
int main(void) {
  struct sync_ptr s = {0, 0, 0}; /* stale userspace pointers */
  struct status status = {3};
  struct ops ops = {fake_ioctl};
  struct pcm p = {&s, &status, &ops, NULL, -1};
  assert(pcm_state(&p) == 3 && calls == 1);
  /* Original source must fail this check, proving regression sensitivity. */
  if (kernel_appl != 320 || kernel_avail != 320)
    return 1;
  assert(s.appl_ptr == 320 && s.avail_min == 320);
  assert(s.flags == (SNDRV_PCM_SYNC_PTR_APPL | SNDRV_PCM_SYNC_PTR_AVAIL_MIN));
  kernel_appl = 480;
  assert(pcm_state(&p) == 3 && s.appl_ptr == 480 && kernel_appl == 480);
  ioctl_error = 1;
  assert(pcm_state(&p) == -1);
  p.sync_ptr = NULL;
  unsigned before = calls;
  assert(pcm_state(&p) == 3 &&
         calls == before); /* mmap status path unchanged */
  puts("Exact upstream pcm_state/sync_ptr fake ioctl regression passed");
  return 0;
}
