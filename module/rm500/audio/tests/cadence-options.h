#ifndef AIRSIM_CADENCE_OPTIONS_H
#define AIRSIM_CADENCE_OPTIONS_H
#include <string.h>
/* No defaults, numeric coercion, duplicate or extra arguments. */
static int cadence_rate(int argc, char **argv, unsigned *rate) {
  if (argc != 3 || strcmp(argv[1], "--playback-rate"))
    return -1;
  if (!strcmp(argv[2], "8000"))
    *rate = 8000;
  else if (!strcmp(argv[2], "16000"))
    *rate = 16000;
  else
    return -1;
  return 0;
}
#endif
