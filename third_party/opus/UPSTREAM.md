# libopus

Source: https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz

Version: `1.5.2`, release tarball `opus-1.5.2.tar.gz`, SHA-256 `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1`.

Only the files the fixed-point build compiles are kept: `include/`, the `celt/`, `silk/`, `silk/fixed/` and `src/` sources listed in `celt_sources.mk`, `silk_sources.mk` and `opus_sources.mk`, with their headers. Every kept file is unmodified. The native helpers build them with `FIXED_POINT` and `DISABLE_FLOAT_API` through `module/rm500/audio/scripts/build_opus.py`.
