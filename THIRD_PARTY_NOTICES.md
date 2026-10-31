# AirSIM Third-Party Notices

AirSIM includes or depends on third-party software. Those components remain governed by their own licenses; the AirSIM project license does not replace them.

## liblc3 v1.1.3

The v2 iOS App and native module audio helpers include [Google liblc3](https://github.com/google/liblc3), commit `96a3af0beb5487aca3b98a4b992a539a1f6d80d1`, under Apache-2.0. The full license is in `third_party/liblc3/LICENSE`; source provenance and the local exponent-arithmetic change are recorded in `third_party/liblc3/UPSTREAM.md`. Module distributions include `LC3-LICENSE.txt`, and the iOS App bundles the same notice.

## euicc-go v1.1.2

Repository: <https://github.com/damonto/euicc-go>

License: MIT

```text
MIT License

Copyright (c) 2025 Damon To

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Cloudflare Wrangler

`push-relay-worker` uses Wrangler as a development and deployment tool. Wrangler and its transitive dependencies retain the licenses recorded in `push-relay-worker/package-lock.json`; they are not relicensed under the AirSIM project license.

## warthog618/sms v0.3.0

The v2 EG25 Agent uses <https://github.com/warthog618/sms> for GSM SMS PDU encoding and decoding.

```text
The MIT License (MIT)

Copyright (c) 2018 Kent Gibson

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## TinyALSA

The native audio helpers include TinyALSA under its BSD license.

```text
Copyright 2011, The Android Open Source Project

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of The Android Open Source Project nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY The Android Open Source Project ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL The Android Open Source Project BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.
```

## QDC507 kernel runtime

The EG25 runtime distributes `airsim_data11.ko` under GPL-2.0-only and `qdc507_aprv3.ko` / `qdc507_voice.ko` from [MaVo commit 0443dfd](https://github.com/moluncn/mavo/tree/0443dfdaf8aec086fd76ba2ee9152fd908114524/Resources/ModuleVoice) under GPL-2.0. The corresponding COPYING-GPL-2.0 and MODULE-REPORT.md accompany the runtime. AirSIM DATA11 source is in `module/eg25/kmod/`.

## Noto Sans SC

The iOS interface includes Noto Sans SC from the [Noto CJK project](https://github.com/notofonts/noto-cjk), licensed under the SIL Open Font License 1.1. The bundled font and full copyright/license notice are in `iOS/AirSIM/Fonts/`.
