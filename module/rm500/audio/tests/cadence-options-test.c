#include "cadence-options.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
  char *args[] = {"probe", "--playback-rate", "8000", "extra"};
  unsigned rate = 0;
  assert(cadence_rate(3, args, &rate) == 0 && rate == 8000 && rate / 50 == 160);
  args[2] = "16000";
  assert(cadence_rate(3, args, &rate) == 0 && rate == 16000 &&
         rate / 50 == 320);
  const char *bad[] = {"",
                       "0",
                       "7999",
                       "8001",
                       "15999",
                       "16001",
                       "48000",
                       "08000",
                       "+8000",
                       "8000 ",
                       " 8000",
                       "8000x",
                       "99999999999999999999"};
  for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    args[2] = (char *)bad[i];
    rate = 123;
    assert(cadence_rate(3, args, &rate) == -1 && rate == 123);
  }
  args[2] = "8000";
  for (int n = 0; n <= 4; n++)
    if (n != 3)
      assert(cadence_rate(n, args, &rate) == -1);
  args[1] = "--capture-rate";
  assert(cadence_rate(3, args, &rate) == -1);
  puts("cadence rate argument boundaries passed");
}
