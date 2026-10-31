#define _GNU_SOURCE
#include "route.h"
#include <fcntl.h>
#include <sound/asound.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <tinyalsa/pcm.h>
#include <unistd.h>

static int control = -1, changed, media_started;
static struct pcm *voice_capture, *voice_playback;
static struct snd_ctl_elem_value saved[4];
static const char *mixers[] = {
    "SEC_AUX_PCM_RX_Voice Mixer VoLTE",
    "VoLTE_Tx Mixer SEC_AUX_PCM_TX_VoLTE",
    "AFE_PCM_RX_Voice Mixer VoLTE",
    "VoLTE_Tx Mixer AFE_PCM_TX_VoLTE",
};

static int media_command(const char *command) {
  int fd = open("/run/voc_svr", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return -1;
  size_t size = strlen(command);
  int result = write(fd, command, size) == (ssize_t)size ? 0 : -1;
  close(fd);
  return result;
}

static int mixer_routes(void) {
  struct snd_ctl_elem_list list = {0};
  control = open("/dev/snd/controlC0", O_RDWR | O_CLOEXEC);
  if (control < 0 || ioctl(control, SNDRV_CTL_IOCTL_ELEM_LIST, &list)) return -1;
  list.space = list.count;
  list.pids = calloc(list.space, sizeof(*list.pids));
  if (!list.pids) return -1;
  int rc = -1;
  if (ioctl(control, SNDRV_CTL_IOCTL_ELEM_LIST, &list)) goto done;
  for (unsigned m = 0; m < 4; m++) {
    unsigned i;
    for (i = 0; i < list.used; i++)
      if (!strcmp((char *)list.pids[i].name, mixers[m])) break;
    if (i == list.used) goto done;
    saved[m].id = list.pids[i];
    if (ioctl(control, SNDRV_CTL_IOCTL_ELEM_READ, &saved[m])) goto done;
    struct snd_ctl_elem_value value = saved[m];
    value.value.integer.value[0] = m < 2 ? 0 : 1;
    if (ioctl(control, SNDRV_CTL_IOCTL_ELEM_WRITE, &value)) goto done;
    changed++;
  }
  rc = 0;
done:
  free(list.pids);
  return rc;
}

int eg25_audio_start(void) { return eg25_audio_start_rate(16000); }

int eg25_audio_start_rate(unsigned rate) {
  if (mixer_routes()) return -1;
  struct pcm_config config = {.channels=1, .rate=rate,
      .period_size=1024, .period_count=2, .format=PCM_FORMAT_S16_LE,
      .start_threshold=1, .stop_threshold=2048, .avail_min=1024};
  voice_capture = pcm_open(0, 4, PCM_IN | PCM_NONBLOCK, &config);
  if (!voice_capture || !pcm_is_ready(voice_capture)) return -1;
  voice_playback = pcm_open(0, 4, PCM_OUT | PCM_NONBLOCK, &config);
  if (!voice_playback || !pcm_is_ready(voice_playback)) return -1;
  if (pcm_prepare(voice_capture) || pcm_prepare(voice_playback) ||
      pcm_start(voice_capture) || pcm_start(voice_playback)) return -1;
  if (media_command("S\n")) return -1;
  media_started = 1;
  return 0;
}

void eg25_audio_stop(void) {
  if (media_started) { media_command("T\nT\nB\n"); media_started=0; }
  if (voice_playback) { pcm_close(voice_playback); voice_playback=NULL; }
  if (voice_capture) { pcm_close(voice_capture); voice_capture=NULL; }
  while (changed > 0) ioctl(control, SNDRV_CTL_IOCTL_ELEM_WRITE, &saved[--changed]);
  if (control >= 0) { close(control); control=-1; }
}

int eg25_audio_reset(void) {
  int result = media_command("T\nT\nB\n");
  if (mixer_routes()) result = -1;
  while (changed > 0) {
    unsigned i = --changed;
    saved[i].value.integer.value[0] = i < 2 ? 1 : 0;
    if (ioctl(control, SNDRV_CTL_IOCTL_ELEM_WRITE, &saved[i])) result = -1;
  }
  if (control >= 0) { close(control); control = -1; }
  return result;
}
