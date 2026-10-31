# liblc3

Source: https://github.com/google/liblc3

Version: `v1.1.3`, commit `96a3af0beb5487aca3b98a4b992a539a1f6d80d1`.

The upstream README and Apache-2.0 license are included. The local change in `src/fastmath.h` uses unsigned arithmetic for IEEE-754 exponent bit manipulation. Other C sources are unmodified. AirSIM builds standard LC3 with `LC3_PLUS=0` and `LC3_PLUS_HR=0`; its fixed media profile and wrapper are in `shared/lc3/`.
