#!/usr/bin/env python3
"""Compile the vendored fixed-point libopus into a static archive.

Usage: build_opus.py OUTPUT.a AR CC [CC ARGS...]
"""
import concurrent.futures
import os
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4] / "third_party/opus"
FLAGS = ["-O2", "-DOPUS_BUILD", "-DFIXED_POINT=1", "-DDISABLE_FLOAT_API", "-DUSE_ALLOCA",
         "-DHAVE_LRINTF", "-DHAVE_LRINT", "-w"] + ["-I" + str(ROOT / d) for d in ("include", "celt", "silk", "silk/fixed", ".")]


def sources():
    names = {}
    for mk in ("silk_sources.mk", "celt_sources.mk", "opus_sources.mk"):
        text = (ROOT / mk).read_text().replace("\\\n", " ")
        for m in re.finditer(r"^(\w+)\s*=\s*(.*)$", text, re.M):
            names[m.group(1)] = m.group(2).split()
    return [ROOT / s for k in ("SILK_SOURCES", "SILK_SOURCES_FIXED", "CELT_SOURCES", "OPUS_SOURCES") for s in names[k]]


def main():
    output, archiver, compiler = pathlib.Path(sys.argv[1]), sys.argv[2].split(), sys.argv[3:]
    with tempfile.TemporaryDirectory() as tmp:
        def build(src):
            obj = pathlib.Path(tmp) / (src.stem + ".o")
            subprocess.run(compiler + FLAGS + ["-c", str(src), "-o", str(obj)], check=True)
            return str(obj)
        with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
            objects = list(pool.map(build, sources()))
        output.parent.mkdir(parents=True, exist_ok=True)
        output.unlink(missing_ok=True)
        subprocess.run(archiver + ["rcs", str(output)] + objects, check=True)


if __name__ == "__main__":
    main()
