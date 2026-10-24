/* Host-only shim: tests never invoke the helper's process entry point. */
#define PR_SET_PDEATHSIG 1
static inline int prctl(int option, int signal_number) {
  (void)option;
  (void)signal_number;
  return -1;
}
