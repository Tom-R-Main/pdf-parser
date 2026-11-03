# Live Linux OCR arithmetic profile

This opt-in quality-boundary profile reproduces the historical candidate counts
with **live PDF → Poppler → Tesseract → adaptive evaluation**. It does not change
the kernel, layout, routing thresholds, metadata, or specialist dispatch. The
recorded external-OCR regression remains a separate lane.

The JPX scan uses irreversible JPEG2000 arithmetic. On the diagnosed Linux build,
OpenJPEG contraction accounted for 64 gray pixels and Poppler's DeviceRGB-to-gray
contraction accounted for another 398; all differences were ±1. Enabling both
reproduced the saved Mac raster's complete RGB hash. Tesseract 5.5.2 then retained
the reference text/geometry (seven tiny confidence-decimal differences), and the
unchanged strict 4-table/6-formula candidate assertion passed. These counts are
conservative routing candidates, not a claim that the map contains four tables
and six equations. Stock Linux Tesseract 5.5.0 / Poppler 26.05 remained 1/5.

## Build locally without replacing installed tools

Requirements: Linux x86_64 with AVX/FMA, Python 3.12+, CMake, Ninja, C/C++23
compilers, binutils, pkg-config, and development libraries for Leptonica, LCMS2,
FreeType, Fontconfig, JPEG, PNG, TIFF and zlib. Pillow is required by the live
raster probe. Unsupported CPUs fail explicitly rather than falling back.

Supply these release archives in a source-cache directory; their URLs and
SHA256 values are pinned in `ocr_profile.py`:

- `openjpeg-2.5.4.tar.gz`
- `poppler-26.02.0.tar.xz`
- `tesseract-5.5.2.tar.gz`

The builder is offline and verifies all archives and the English model before
extraction or compilation. Model SHA256 must be
`7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`.
It writes only the selected output directory and preserves existing profiles.

```sh
python3 benchmark/eval/ocr_profile.py build \
  --source-cache /path/to/verified-release-archives \
  --traineddata /path/to/eng.traineddata \
  --output benchmark/eval/outputs/live-ocr-profile
```

`--cmake`, `--ninja`, and `--dependency-prefix` support existing project-local
build tools and development libraries. The build enables `-mfma
-ffp-contract=fast` for OpenJPEG and only Poppler's `GfxState.cc`; it rejects
global `-ffast-math` and unsafe-math flags. RelWithDebInfo avoids OpenJPEG's
upstream GNU Release-only fast-math default. Tesseract's pinned upstream
`src/arch/dotproduct.cpp` retains its file-specific `-ffast-math`; propagation
to any other source file fails validation. Tesseract disables native tuning,
optional network/archive dependencies, graphics and training tools. This
profile selects serial Tesseract to bound build/runtime dependencies and worker
cleanup; serial execution is not asserted to be required for numeric parity.

## Qualify real tools and unchanged expectations

```sh
zig build --summary all
zig build benchmark-eval --summary all
python3 benchmark/eval/ocr_profile.py gate \
  --profile benchmark/eval/outputs/live-ocr-profile/profile.json \
  --output benchmark/eval/outputs/live-ocr-qualified
```

The gate verifies executable/model hashes and the actual loaded OpenJPEG DSO,
renders the original JPX PDF and checks decoded RGB pixels, runs the **entire
original strict corpus**, and runs existing live form, JBIG2 and JPX semantic
quality gates with explicit tool-version guards. It never reads stored TSV or
PNG as provider input. Every subprocess has an owned process group, timeout,
exit status, duration and retained logs. Failures remain failures.

Source pins and contraction flags do not imply universal platform parity:
compiler, loaded image/color libraries and Leptonica identities remain part of
the receipt. Run the gate on each environment. This profile does not replace the
separate package-pinned OCR qualification or Memcheck lanes. No performance or
whole-process memory claim follows from a passing quality gate.
