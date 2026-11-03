# Browser WASM API

Build with Zig 0.17.0:

```sh
zig build wasm --summary all
node benchmark/eval/wasm/stage.mjs deploy
```

Serve the resulting directory over HTTP. It contains the HTML demo, matching
JavaScript modules, `pdf_parser.wasm`, and a manifest of asset hashes. The demo
runs extraction in a module Worker. Input stays on the device; the Worker loads
the WASM asset from the same static site.

For an application that needs asynchronous extraction:

```js
import { PDFParserWorker } from './pdf-parser-worker.mjs';

const parser = new PDFParserWorker();
try {
    await parser.init();
    const { pageCount, text, warningCount } = await parser.extract(pdfBytes, {
        signal: abortController.signal,
    });
} finally {
    parser.dispose();
}
```

One document may be active per client. A second concurrent extraction rejects
with `code: 'busy'`; there is no hidden queue. Input is snapshotted before
initialization is awaited, then an independent copy is transferred to the Worker.
The caller retains its original buffer. Returned strings own their storage.

`cancel()` or an aborted signal terminates the Worker and rejects pending work
with `AbortError`. The next extraction creates a new Worker and module instance.
`dispose()` also terminates work and permanently closes that client. A timeout
terminates the Worker and rejects with `code: 'timeout'`. A cancellation message
inside a Worker would not interrupt a synchronous guest call, so termination is
the cancellation boundary.

## Limits

Constructor options apply per client:

| Option | Default | Scope |
| --- | --- | --- |
| `maxInputBytes` | 32 MiB | Accepted PDF bytes before guest copying; demo checks file size before reading |
| `maxOutputBytes` | 16 MiB | Serialized UTF-8 output, checked before appending to the result |
| `maxDecodedStreamBytes` | 32 MiB | Output per decoded stream/filter stage |
| `timeoutMs` | 45,000 ms | Each initialization/extraction request; expiry terminates the Worker |

The module's linear-memory maximum defaults to 512 MiB. Override it with
`zig build wasm -Dwasm-max-memory=268435456` for a 256 MiB ceiling. The build
option must be page aligned and between 4 MiB and 4 GiB; a value below the
module's required initial memory cannot link. These are configurable policies,
not a demonstrated PDF size/page capacity or a browser process-memory bound.

Output limits do not bound temporary per-page results or document caches.
Decoded-stream limits and the module ceiling are separate controls. JavaScript
copies, decoded strings, compiled code and browser overhead are outside linear
memory. Multiple clients have independent budgets and can consume more memory.

`warningCount` is the number of recoverable parser diagnostics, not a coverage
or completeness certificate. Header validation rejects non-PDF input, while
header-bearing malformed files may still open under permissive parsing. This
surface uses native structured-text extraction. OCR, specialist execution,
password configuration and adaptive artifact/stream JSONL are not exposed here.
The adaptive schema version and native CLI/C/Python contracts are unchanged.

## Direct module ownership

`PDFParser` from `pdf-parser.mjs` supplies a synchronous API after `await init()`.
Use it inside a Worker for costly browser input. `wasmBytes` accepts compiled
binary bytes for hosts such as Node; otherwise initialization fetches `wasmUrl`
and preserves HTTP failures. Repeated `init()` calls share one promise.

`openPDF(bytes)` copies an ArrayBuffer or Uint8Array into guest memory and returns
a document owned by that parser instance. Keep it until extraction finishes,
then call `closePDF(doc)` in `finally`. Close is idempotent. Closed documents and
documents from another wrapper reject. `extractDocument(bytes)` handles this
lifecycle and returns `{pageCount, text, warningCount}`. `extractPage(doc, index)`
and `extractAll(doc)` return owned strings. A guest trap makes the owner
unusable; dispose its instance instead of attempting further guest operations.

## Raw numeric ABI v2

`pdf_parser_wasm_abi_version()` returns `2`. Addresses, lengths and handles are
wasm32 integers. Output scalars are little-endian 32-bit values. Input and output
allocations use `wasm_alloc` / `wasm_free`, with the original pointer and length.
The raw host must supply valid live allocations; linear range checks do not
prove allocation ownership. Input remains borrowed until document close.

| Export | Arguments after the name |
| --- | --- |
| `pdf_parser_wasm_open` | `data, length, maxDecodedBytes, outHandle` |
| `pdf_parser_wasm_close` | `handle` |
| `pdf_parser_wasm_page_count` | `handle, outCount` |
| `pdf_parser_wasm_error_count` | `handle, outCount` |
| `pdf_parser_wasm_extract_page` | `handle, pageIndex, maxOutputBytes, outPointer, outLength` |
| `pdf_parser_wasm_extract_all` | `handle, maxOutputBytes, outPointer, outLength` |

All operations above return a status:

| Status | Meaning |
| --- | --- |
| 0 | Success; an empty extraction returns pointer 0 and length 0 |
| 1 | Invalid argument, range, alignment, output alias or zero limit |
| 2 | Invalid or stale handle |
| 3 | Invalid page index |
| 4 | All 16 v2 document slots are occupied or retired |
| 5 | Opening failed |
| 6 | Extraction failed |
| 7 | Allocation, decoded-stream or serialized-output limit refused work |

Valid output scalars clear before a failure. An output handle overlapping input
is rejected without clearing it, preserving the input bytes. Extraction outputs
must be separate scalar addresses. After success, copy/decode the output before
freeing it. Reacquire views from `memory.buffer` after guest calls that may grow
memory. Aggregate text separates pages with form-feed, including empty pages.

V2 handles include a generation and are scoped to their instance. Closing revokes
the identity before destruction; exhausted generations retire rather than wrap.
Legacy `zpdf_*` exports retain their separate 16-slot table and original handle
semantics. They remain callable, including their legacy stale-slot limitation;
new consumers should use v2. The new wrapper requires ABI v2.

## Verification

See [the WASM test recipe](../benchmark/eval/wasm/README.md). The Node suite calls
the final binary through the public wrapper and raw ABI. The browser gate stages
the same asset set as deployment, drives the demo's file input, checks semantic
output and exercises real Worker cancellation/recovery. Neither gate alone
qualifies another browser, deployed Pages, general PDF correctness or performance.
