# WASM improvement review — November 1, 2026

The best next investment is an executed browser/ABI contract with reliable
cleanup, errors and document identity. Preserve the existing Zig freestanding
module. Workers and richer artifacts are useful follow-on work; a toolchain
rewrite, WASI component conversion or unmeasured optimizer pass has no evidence
of benefit for this browser consumer.

This review applies the installed `wasm` and `repo-learn` skills to target revision
`ddf9d6811329c4fb1a655c6be46e126b9a9ffc5a`. It adds research documentation and
ignored local probes, not a parser implementation, workflow change or global
skill edit. Reference checkouts remained read-only. No fetch, install, commit,
publication or deployment occurred.

## Current boundary and executed evidence

`build.zig:72–85` builds `src/wapi.zig` for `wasm32-freestanding`, optimization
`small`, entry disabled and exported symbols retained. This is a callable core
module with a handwritten numeric ABI, not WASI or a component. The actual
artifact validates and instantiates in Node and Chromium with no imports.
It exports linear memory, allocation/free, document operations, text/Markdown,
page information and bounds; it has no adaptive JSONL or ABI-version export.

`web/index.html:233–425` embeds the only browser wrapper and UI. The wrapper
copies input into the guest and keeps it until document close, matching
`Document.openFromMemoryUnsafe`'s borrowed-input contract. It creates fresh
typed-array views after guest operations and decodes output into an owned JS
string before freeing. **Keep these properties.** Forced growth and subsequent
close did not invalidate the returned string in the executed controls.

| Executed check | Result and boundary |
| --- | --- |
| `zig version`; `zig build wasm --summary all` | Zig 0.17.0; 5/5 build steps, cached compilation |
| Final binary | 3,192,489 bytes; SHA-256 `a45432197a255efe717be825866cf035919333d03eb73f90e5f4b8666d65fe01` |
| Size headroom | 57,511 bytes under CI's 3,250,000-byte cap; raw binary size only |
| Binary memory section | Minimum 57 pages; no declared maximum; this does not establish actual browser allocation limits |
| Node 22.17.1 | Nine observational checks against the actual WASM and HTML class/functions; normalized clean fixture text equals checked-in truth |
| Chromium 156 | Staged HTML/binary over localhost under a nested path: page count, expected text, visible UI output and retained strings across growth passed |
| Missing binary | Real HTTP 404 becomes a WASM magic-word CompileError; loading fails, but HTTP identity is lost |
| Readiness injection | A new uninitialized wrapper reaches `wasm_alloc` and raises a null-property error through actual browser `processFile` |

The Node probe deliberately records problematic current behavior as observations;
its nine passing assertions are **not nine corrected behaviors**. One initial
expectation that three non-PDF bytes would be rejected failed. Follow-up observed
that they open as a zero-page document and extract `''` under permissive defaults.
This is a boundary-policy finding, not proof that strict native parsing fails.

## Prioritized implementation slices

| Order | Change and reason | Acceptance check |
| --- | --- | --- |
| 1 | Extract the reusable browser wrapper from inline HTML, establish one initialization promise/ready state, and add Node plus staged-browser execution to CI. Current WASM CI builds and checks size only. | Run the actual final asset set with clean text, an empty scan, invalid page, nested URL and missing binary. Fail on a deliberately incorrect expected result. Disable or await input until ready. |
| 2 | Make JS allocation/document cleanup unconditional and close idempotent. Current sequential frees/close are skipped on exceptions. | Inject decoding failure after output allocation and extraction failure after document open. Assert each acquired buffer/document is released exactly once, and input is freed after document close. |
| 3 | Introduce a versioned status/result and document-handle contract while keeping legacy exports compatible. Empty success, invalid page/handle, capacity and extraction failure need distinct outcomes. | Clear output lengths on failure; preserve empty success; reject a closed wrapper and an old native handle after slot reuse without touching its replacement. Explicitly test parse-policy/diagnostic behavior. |
| 4 | Move costly extraction to an owned Worker, with bounded admission, input/output limits and request settlement. Start with one active document/job; measure before increasing concurrency. | Verify a UI heartbeat during work; correlated success/error responses; bounded queued bytes; cancellation rejects every pending request. Hard cancellation terminates/recreates the Worker; a message cannot interrupt the current synchronous guest call. |
| 5 | Add a native-only, provenance-preserving artifact surface if browser consumers need more than strings. Reuse schema semantics and serializer owners. | Compile a no-host-I/O path, assert source/input identity, page/bbox/source/confidence and deterministic records against representative fixtures. Preserve unavailable-specialist/coverage outcomes. Recheck size before accepting added reachability. |

The first two slices can improve the existing consumer without silently changing
its raw ABI. For slice 3, use additive exports/version negotiation for the richer
contract; do not silently change what legacy slot handles mean. Wrapper closed
state prevents ordinary JS reuse, but only native identity validation can reject
arbitrary stale numeric aliases. Reuse the existing generational-handle lesson;
opaque handles are not authorization or concurrency control.

### Reproduced lifecycle and error boundaries

- `src/wapi.zig:13–21,44–80`: after opening handle 0, closing it, and opening a
  replacement, the old handle again reports the replacement's page count. Calling
  close with the old handle closes the replacement. This was executed against the
  built module, not inferred from a handle model.
- `src/wapi.zig:83–105` and the JS wrapper: invalid page `-1` returns the same
  empty JS string as successful extraction of the image-only fixture. An invalid
  handle also leaves a caller-written output-length sentinel unchanged. The
  current JS wrapper checks null before reading it, so this does not demonstrate
  an out-of-bounds read in that wrapper.
- `web/index.html:311–355,386–425`: injected host decode failure after real guest
  extraction caused zero frees; injected extraction failure after real document
  opening caused zero closes. These controlled exceptions demonstrate skipped
  cleanup, not naturally occurring guest traps or measured memory exhaustion.
- The 17th simultaneously live document is rejected; releasing a slot allows
  another open. Capacity failure currently shares the generic open-error channel.

For guest traps, define whether the instance is disposable before attempting
more guest cleanup. For ordinary JS exceptions, use nested `try/finally` around
successful acquisitions. Do not make garbage-collection timing the primary
ownership contract or free input before its borrowed document is closed.

### Resource and artifact compatibility

A Worker changes responsiveness and provides a termination boundary; it does not
bound allocations or eliminate serialization. Keep separate controls for input
bytes, guest allocation growth, decoded streams, output bytes and pending work.
The current WASM API uses `std.heap.wasm_allocator` directly and exposes no such
options. The binary has no maximum-memory declaration. Choose and test a budget
against representative devices rather than inventing a universal number here.

Reuse `resource_limits.zig` where ownership permits, but its own documentation
excludes document caches and other allocations outside that wrapper.
`adapter.zig:41–51` currently accepts output/page limits only for `stream_jsonl`;
it would reject those options on batch artifact output. Do not promise that
passing this existing struct automatically budgets a new browser batch API.

The native C adaptive entry is not a ready-made WASM export: `capi.zig:262–302`
constructs `std.Io.Threaded`, and adapter options include file/config output.
`adaptive.ExtractOptions` enables OCR by default. A browser-native path must
explicitly exclude unavailable filesystem/subprocess/specialist work and prove
the selected calls compile without imports. The current string/bounds API does
not establish schema-0.20 adaptive parity. Any public JSON field changes still
follow `docs/output-schema.md` and the schema-version policy.

## Reference mechanisms and rejected transfers

| Reference at inspected revision | Mechanism and target fit | Counterexample / limit |
| --- | --- | --- |
| DuckDB-WASM `1f85a503e0c25f0c0980f205915de328c923f476`, `bindings_base.ts:708–719`, `worker_dispatcher.ts:385–403`, `filesystem.test.ts:124–147` | Own output before releasing native storage; test public decoded content. Apply to future byte/bounds and Worker APIs. Existing string output already owns its result. | COPY_FILE_TO_BUFFER uses an empty transfer list, so Worker use alone does not prove zero-copy. Its public test does not force growth. |
| Automerge `5bae7757ef7b92c8cd6850def388f22767305ccb`, `javascript/packaging_tests/run.mjs:350–427`, `vite_slim/main.js:1–28` | Test delivered artifacts in isolated consumers and await initialization. For this repo stage HTML + WASM, with no need for npm, Vite or wasm-bindgen. | At `run.mjs:138–240`, one production Vite caller discards the boolean content verdict from `loadTestPage`. Transfer the assertion mechanism and verify its failure propagation, not the harness unchanged. |
| MuPDF `63c8e2652fcb9207b5bba9ecb4fb366b160ff85f`, `platform/wasm/lib/mupdf.c:49–75`, `mupdf.ts:661–689,1418–1441`, `examples/simple-viewer/worker.js:26–85` | Preserve failure identity, explicitly destroy wrappers, release output in finally, and correlate Worker results/errors. | Its `openDocument` temporary cleanup at `mupdf.ts:2010–2049` lacks finally around opening. Its refcounted input, Emscripten bridge and rendering scope differ from this parser's borrowed input and freestanding ABI. The example's error serializer also assumes Error objects despite special string throws. |

These are mechanism references, not proposed source copies or dependencies.
No upstream suites were executed. Scoped MuPDF searches found build/viewer
recipes but no decisive WASM lifecycle test; that partial result is not proof
that no external test suite exists.

No evidence warrants mandatory shared memory, threads, SIMD, memory64, WIT,
component hosts, Rust/Go glue or another browser framework here. Likewise there
is no measured speedup from adding `wasm-opt`, switching optimization modes or
calling a Worker. A later performance study should separate load/compile,
input copy/open, extraction, output conversion, scheduling and memory retention,
using native/JS baselines with matched output semantics. The demo's displayed
timer excludes download/compile and file reading, so it is not end-to-end latency.

## Durable learning and reproduction

Task store, within the approved project and outside the reference checkouts:

`benchmark/eval/outputs/wasm-review-2026-11-01/library`

SQLite is canonical; `library/patterns.md` and evidence JSON are inspectable
exports. Eleven bounded source anchors were rehashed fresh. The pre-existing
collection and wasm-skill stores were consulted read-only through exported cards;
neither was replaced or modified. Existing ownership, generation and decoder
budget lessons were reused. Two distinct local cards cover final-consumer verdict
propagation and host-exception cleanup; they retain prior owner IDs and rejected
applications. They do not imply that target fixes have shipped.

A fresh-context alternate-wording retrieval check ranked the delivery card first
for a static site that builds but displays incorrect text, and the cleanup card
first for a decoder exception followed by accumulating document slots. It also
rejected imposing WIT components/npm bundling for initialization alone. This
checks retrieval and applicability judgment, not runtime correctness.

The helper refuses to catalog a target that contains its own store. That check
was respected: target sources were inspected directly and their hashes recorded
in `target-source-receipt.json`; reference evidence uses helper snapshots.

```sh
zig build wasm --summary all
node benchmark/eval/outputs/wasm-review-2026-11-01/target-probe.mjs
python3 benchmark/eval/outputs/wasm-review-2026-11-01/serve.py
# Open the printed localhost port at /nested/parser/index.html.
# /missing/index.html exercises a missing binary.
```

Detailed observations are in `target-results.json` and `browser-results.json`
beside the probes. Probes use the actual HTML wrapper; UI exception injection in
Node uses a DOM stub. Browser checks used real Chromium and local staged assets,
not deployed GitHub Pages. No full corpus, performance, browser matrix, resource
exhaustion or component-host qualification was performed. Task-owned HTTP server
and browser tab were closed. No full native suite was needed for documentation
and ignored research outputs; implementation must use the Zig/domain skills and
repository gates, plus the actual WASM consumer checks described above.
