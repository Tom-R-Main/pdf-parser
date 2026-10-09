# Memory checks

Use ordinary Zig tests for safe-mode checks and allocation-failure cleanup. Use
Memcheck to examine executed CLI and shared-library paths. A passing run does
not establish complete memory safety, race freedom, or a total memory budget.

## Build diagnostic artifacts

Select the compiler pinned in `.zig-version`, then build both configurations:

```sh
zig version
zig build --summary all
zig build memcheck-build --summary all
```

The diagnostic CLI and shared library install under `zig-out/memcheck/`, along
with `build-info.json` and an isolated arena probe. They use debug mode, LLVM,
symbols, frame pointers, a baseline CPU target, and libc-backed application
allocation. A transparent allocator wrapper also counts live application blocks
and requested bytes without changing libc addresses or allocation boundaries.
Normal artifacts and their allocators keep their existing paths.
The public ABI and JSONL schema stay the same.

macOS diagnostic standard streams use Zig's streaming writer, avoiding the
fork's unsupported `pwritev` positional probe on stdout/stderr. Parser file I/O
keeps its existing path; the diagnostic OCR driver reads its bounded PGM header
through libc to avoid unsupported `preadv`. A new unsupported syscall fails verification; it is not
a memory-error suppression.
Zig error-return tracing is disabled only in macOS diagnostic artifacts because
its stack printer reads debug files through unsupported `preadv`. Error messages
and exit status remain visible. Debug symbols, unwind information, Memcheck
allocation/free/use stacks, and Zig runtime safety checks remain enabled.

Zig 0.17 rejects its compiler Valgrind flag on ARM64. Diagnostic builds enable
that flag on x86 and AMD64; ARM64 builds rely on the checker intercepting libc
allocation. Startup and I/O internals can still use Zig's own allocators.

## Run Memcheck

The runner needs Valgrind, a C compiler, and Python. It never installs tools.
Pass a Python interpreter with `cffi` to check the Python binding too:

```sh
python3 benchmark/eval/memcheck_runner.py \
  --baseline-prefix zig-out \
  --python "$PWD/.venv/bin/python"
```

Each run writes a fresh evidence directory under ignored
`benchmark/eval/outputs/memcheck/`. An explicit `--output` must name a new
directory. The summary records build identity, artifact hashes, revision and
local changes, commands, versions, coverage, skips, exit status, and complete
stdout/stderr and Memcheck XML logs. Keep these logs when diagnosing a report.
Linux reports include resolved shared-library paths and hashes. Memcheck keeps
debug information for unloaded libraries so shutdown reports retain their origin.

Qualification runs a clean control and separate C programs containing an
invalid heap write, a use-after-free, and a definite leak. Each negative case
must produce its expected Memcheck error kind and exit code 77. A tool failure,
crash, or missing report does not qualify the checker. The faulty programs are
isolated from ordinary tests and parser artifacts.
An additional loader-only control opens and closes the shared library without
calling parser functions, exposing dependency initialization separately.

On macOS, a framework Python launcher can re-exec without instrumentation. The
runner selects the corresponding framework interpreter directly and preserves
the requested virtualenv prefix through Python's launcher setting. A completed
Memcheck XML report remains mandatory. Python findings fail that check while
the independent OCR lane continues; they are not converted into a native pass.
Before extraction, an imports-only control resolves the same binding and library
and performs zero PDF operations. Both the control and extraction must pass;
the runner never subtracts control findings from extraction findings.

The local Homebrew Python 3.14.5 build has reported uninitialized-value and leak
findings that also reproduce in an imports-only control without PDF operations.
These prevent whole-interpreter qualification; no general interpreter suppression is supplied. Omit
`--python` to check the native CLI, C ABI, and OCR independently. Use native smoke
mode to exercise bindings functionally, and use a separately qualified Python
runtime for a clean host memory check.

CI explicitly selects `--python-leak-policy parser-allocations`. CLI, C ABI,
allocator controls, and OCR retain full-process Memcheck leak gates. Python
retains Memcheck invalid-access and undefined-value gates, and requires both
diagnostic native counters to return to zero after each document, adaptive
result, and rejected-input lifecycle. The counters observe allocations through
the parser's application allocator, including arena backing blocks; they do
not measure Python objects, foreign-library allocations, or mappings outside
that allocator. A retained-document negative control must be rejected, and a
separate allocator probe qualifies allocation failure, resize, remap, and free
accounting. Counter symbols exist only in diagnostic libraries.

In this explicit mode, complete Python shutdown leak reports remain in the XML
and summary but do not gate CI. The summary sets
`python_process_shutdown_qualified` and `memcheck_proven` to false; successful
instrumented parser checks set `parser_memory_checks_passed` to true. Interpreter
shutdown leak records are grouped by allocation site without changing totals.
This is parser lifetime and access
verification, not a claim that CPython/CFFI process shutdown is leak-free.
`full-process` remains the default and rejects the interpreter findings. Ubuntu
Python 3.12 and GitHub's Python 3.13.16 reproduce shutdown losses even for
`print(1)`; CFFI-only macOS controls also retain GC-prefixed objects. A diagnostic
CPython 3.14.7 build eliminated the observed definedness reports, while `TZ=''`
eliminated the macOS timezone notification reports. Other interpreter retention
remains outside the qualified parser scope.

The parser checks repeat document and result lifetimes through the C ABI,
validate CLI text and both adaptive JSONL modes, and test malformed/truncated
inputs and invalid arguments. Baseline comparison checks output semantics.
Malformed inputs can produce empty documents in permissive mode; strict
adaptive extraction must reject the harness's malformed and truncated inputs.

The runner shows every leak category and treats definite, indirect, and
possible leaks as errors. Reachable allocations remain visible in the XML.
Default suppressions are disabled; the default run supplies no project suppressions.
Inspect the allocation/free/use stacks before introducing a narrow suppression
with a trigger, tool/library version, and reason. A suppression changes coverage.

## Optional OCR check

This lane runs recognition and teardown three times using a raster of the small
checked-in scanned fixture. It requires Tesseract's development libraries and
English data, Leptonica, and `pdftoppm`:

```sh
zig build memcheck-build -Dtesseract-c=true --summary all
python3 benchmark/eval/memcheck_runner.py \
  --baseline-prefix zig-out --python "$PWD/.venv/bin/python" --ocr
```

On Linux, supply the installed include and library directories, for example
`-Dtesseract-include=/usr/include -Dtesseract-lib=/usr/lib/x86_64-linux-gnu`.
Requesting OCR with a build that lacks the backend fails instead of skipping it.
The normal scanned CLI cases disable OCR; the separate OCR executable exercises
the in-process C backend directly.

### Linux dependency lifecycle

Ubuntu 24.04's OpenMP-enabled Tesseract dependency reports 104 definitely lost
bytes when loaded and unloaded, even without parser calls. The same allocations
reproduce by loading `libgomp.so.1` alone; `omp_pause_resource_all(omp_pause_hard)`
does not release them. GCC's initialization stores runtime configuration in
global allocations that its unload destructor does not free.

The CI memory lane therefore builds pinned Tesseract 5.3.4 with its supported
`OPENMP_BUILD=OFF` option. It checks actual library unloading and repeated OCR
recognition without suppressing those leaks or retaining a library handle.
This qualifies the serial OCR configuration. The separate OCR quality job uses
the distribution executable. OpenMP execution and unloading are not covered by
the serial memory lane.

Use the same source build locally when testing unloading. Pass its include and
library directories to `memcheck-build`; diagnostic builds select Tesseract
directly rather than allowing pkg-config to select another installation. Set
`LD_LIBRARY_PATH` to the selected build's library directory and
`TESSDATA_PREFIX=/usr/share/tesseract-ocr/5/tessdata` for Ubuntu's English data.
The pinned source and CMake commands are in
[the CI workflow](../.github/workflows/ci.yml).

## Local macOS option

Upstream Valgrind does not list ARM64 macOS. The
[LouisBrunner fork](https://github.com/LouisBrunner/valgrind-macos#status) lists
macOS 26 ARM64 support. Its ARM64 macOS 15 configuration remains experimental;
check its current support matrix before using another OS version.

After approving local installation, follow that fork's installation instructions
and qualify it with this runner. Record the fork revision as well as the reported
Valgrind version. Linux CI uses upstream Valgrind and qualifies it independently.

If Homebrew requires Command Line Tools but Xcode already supplies the SDK, a
source build can install into the project's ignored cache. Select that executable
explicitly rather than changing the global PATH:

```sh
python3 benchmark/eval/memcheck_runner.py \
  --valgrind "$PWD/.zig-cache/valgrind-install/bin/valgrind" \
  --valgrind-revision "$(git -C .zig-cache/valgrind-macos-src rev-parse HEAD)" \
  --suppressions benchmark/eval/memcheck-macos26.supp \
  --baseline-prefix zig-out --python "$PWD/.venv/bin/python" --ocr
```

The optional macOS 26 suppression file covers non-reachable leaks with system
Objective-C or Swift allocation frames and named image, CoreFoundation, or
CoreGraphics initialization paths. Reports reproduce with the clean C control
or the loader-only control, without PDF operations. The fork also describes
system startup allocation reports in its
[Tahoe system-suppression issue](https://github.com/LouisBrunner/valgrind-macos/issues/198).
The file leaves reachable allocations, invalid accesses, and definedness errors
visible. Its hash and each suppression's count are recorded. Linux CI supplies
no suppression file. Preserve unsuppressed controls when changing OS or tool
versions, and requalify all deliberate faults with the selected suppressions.

For functional verification without an installed checker:

```sh
python3 benchmark/eval/memcheck_runner.py --without-valgrind \
  --baseline-prefix zig-out --python "$PWD/.venv/bin/python" --ocr
```

This is native smoke evidence only. Its summary sets `memcheck_proven` to false
and records the skipped qualification. A requested checker that is missing,
or a timed-out check, fails the normal run.

## Arena coverage and recovery

Libc allocation exposes backing blocks, not every object within an arena. The
isolated `memcheck-arena` probe deliberately writes into an adjacent logical
object inside a live slab. Its expected clean Memcheck result demonstrates the
coverage limit; it is not a successful detection test. Ordinary slice bounds,
ownership invariants, and allocation-failure tests remain necessary.

Do not annotate whole slabs as defined to silence unexplained reports. Add
precise allocator annotations only after qualifying their addressability,
definedness, free, and reset behavior with isolated probes.

If a diagnostic run fails, preserve its evidence and reproducer. Ordinary builds
can continue using their normal paths while the report is investigated. Removing
the isolated CI job and diagnostic build step does not require a schema change.
Do not use Memcheck timings for performance claims.
