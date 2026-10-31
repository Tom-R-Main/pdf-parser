# Usage and integration

Run examples from the repository root after `zig build`. Commands using the
short executable name assume `zig-out/bin` is on your current shell PATH:

```sh
export PATH="$PWD/zig-out/bin:$PATH"
```

For the default ingestion path, start with
`pdf-parser extract-adaptive --input document.pdf --format artifact-jsonl`.
The [output schema](output-schema.md) owns record and compatibility details.

## Library

```zig
const std = @import("std");
const pdf_parser = @import("pdf_parser");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const doc = try pdf_parser.Document.open(allocator, "file.pdf");
    defer doc.close();

    var buf: [4096]u8 = undefined;
    var bw = std.Io.File.stdout().writer(init.io, &buf);
    const writer = &bw.interface;
    defer writer.flush() catch {};

    for (0..doc.pageCount()) |page_num| {
        try doc.extractText(page_num, writer);
    }
}
```

## CLI

```bash
pdf-parser extract document.pdf              # Extract all pages (uses structure tree for reading order)
pdf-parser extract -p 1-10 document.pdf      # Extract pages 1-10
pdf-parser extract -o out.txt document.pdf   # Output to file
pdf-parser extract --fast document.pdf       # Cheaper stream-order native lane
pdf-parser extract --raw-recall document.pdf # Loss-minimizing search/diagnostic channel
pdf-parser extract --adaptive -f json doc.pdf
pdf-parser extract --adaptive -f jsonl doc.pdf
pdf-parser extract --adaptive -f artifact-jsonl doc.pdf
pdf-parser extract --adaptive -f stream-jsonl doc.pdf
pdf-parser extract --adaptive -f rag-jsonl doc.pdf
pdf-parser extract --adaptive --no-ocr -f artifact-jsonl doc.pdf
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format artifact-jsonl
pdf-parser extract-adaptive --input doc.pdf --source-id external-123 --format artifact-jsonl \
  --emit-specialist-requests requests.jsonl
pdf-parser extract-adaptive --input doc.pdf --format artifact-jsonl --debug-assets-dir review-assets
pdf-parser extract --adaptive -f hocr doc.pdf
pdf-parser extract --adaptive -f alto doc.pdf
pdf-parser extract --adaptive -f debug-svg doc.pdf
pdf-parser extract --adaptive --trace doc.pdf
pdf-parser inspect complexity doc.pdf --format json
pdf-parser inspect extraction doc.pdf --format json
pdf-parser search "Evaluation summary" document.pdf # Normalized, multi-source phrase search
pdf-parser info document.pdf                 # Show document info
pdf-parser bench document.pdf                # Run benchmark
pdf-parser benchmark --manifest benchmark/eval/corpus/manifest.tsv \
  --tools pdf-parser:adaptive --output /tmp/pdf-parser-scorecard.json
```

`--fast` skips structure-tree, layout/table reconstruction, and the readable
Poppler fallback while retaining native decoding and AcroForm text. Use it for
throughput-sensitive text ingestion where content-stream order is acceptable;
the default accuracy lane remains the quality contract.

## Search semantics

`pdf-parser search` uses the rich native search path. It normalizes ASCII case,
Unicode whitespace, compatibility hyphens and quotes, common presentation
ligatures, and conservative line-end hyphenation. Each page compares structured,
full-context, native reading-order, and native content-order views, unions their
matches, and conservatively deduplicates occurrences only when supported by
normalized page identity, exact glyph evidence, or matching local context.
Candidates without one of those signals are
retained rather than silently dropped. Results
identify their source. Reproducible text views report byte offsets; native
glyph-backed results expose exact sorted glyph indices within the extraction run;
the first/last fields are a compatibility envelope. They retain geometry through
the Zig API. Bind locators to the input and extraction identity before persisting
them. Search normalization removes PDF layout controls such as
zero-width space and word joiner but preserves script-shaping ZWNJ and ZWJ.

The existing `Document.search`, C `zpdf_search`, and Python `Document.search`
surfaces remain compatibility APIs: ASCII-case-insensitive exact substring
matching over structured extraction with independently allocated context
strings. New Zig callers can use `Document.searchDetailed` and must call
`SearchReport.deinit`. Its `page_failures` distinguishes a partial search from
a true no-match result, while `pages_searched` reports the number of document
pages considered (including for a query that normalizes to empty). Full-context
inventory hits may have no geometry when their text came from a Form XObject or
document-scoped AcroForm value that is not represented in the native glyph
collector.

`inspect extraction` includes per-font CMap, CIDSystemInfo, ToUnicode,
embedded-font, CIDToGIDMap, and Unicode mapping-provenance counters so missing
text can be attributed to a specific font and mapping layer. It also counts
bounded Type3 CharProc `d0`/`d1` metric and bounding-box captures separately
from rendering support. Selection diagnostics compare reading-order candidates
with a Form-aware full-context
Unicode inventory and report missing/extra codepoints, decoded Form XObjects,
coverage, and the selected output path.

Readable extraction now preserves glyph geometry through a native layout pass
that classifies joins, spaces, line breaks, block breaks, and region breaks with
confidence and provenance. The raw recall channel remains separate. Before
readable/RAG output, native layout is gated on boundary/token/line metrics,
extreme token and line rates, and non-whitespace recall. If it fails, the CLI
runs one document-level `pdftotext` process and marks those spans as
`poppler_text` (`external_text` provenance). Native region/gutter segmentation
is used for columns; adaptive region routing emits one primary specialist
request per region.

Adaptive extraction keeps fast native extraction on the default path while
recording when a page or region should be routed elsewhere. Current route names
include `use_native`, `queue_ocr`, `candidate_layout`, `candidate_table`,
`candidate_formula`, and `candidate_table_formula`. The trace JSON reports page
index, region index, span count, route, confidence, signal scores, and reasons
such as `image_dominant`, `missing_tounicode`, `table_alignment`,
`formula_density`, and `low_reading_order_confidence`. Use `--no-ocr` when a
host pipeline wants adaptive structure and routing evidence without invoking
fresh OCR subprocesses.

Adaptive `json` emits the versioned public schema: a `document_manifest` plus
typed `span`, `block`, `table`, `form_field`, `route_trace`,
`specialist_request`, `specialist_response`, `specialist_result`, `rag_chunk`,
and `debug_asset` records. `artifact-jsonl` emits the same contract as a
manifest-first batch JSONL stream for host applications and ingestion
pipelines. Schema `0.11.0` added one `specialist_attempt` record per OCR
invocation, including configuration, bounded diagnostics, quality signals, and
the selected attempt. Schema `0.12.0` added document-global specialist request
identity across batch/streaming output and the first optional, bounded formula
JSONL subprocess lifecycle. Schema `0.13.0` closes the visual loop for
file-backed, unrotated pages: routed formula regions become deterministic,
page-clamped PNG crops; successful responses replace overlapping native spans
with `formula_model` spans and provenance-bearing formula artifacts. Crop or
specialist failures leave native text intact.
`stream-jsonl` emits page-by-page lifecycle events and artifacts as
soon as each page is processed: `document_manifest`, `page_started`, route
traces, specialist requests/results, page artifacts, `page_finished`, optional
debug assets, then `document_finished`. `jsonl` remains a compatibility span
stream, and `rag-jsonl` remains chunk-only. The schema is documented in
[docs/output-schema.md](output-schema.md).

Visual review assets remain formal `debug_asset` records (introduced in schema
`0.11.0`). By
default they are references with `path:null`, `uri:null`, and null hashes. Add
`--debug-assets-dir DIR` to materialize deterministic sidecar files such as
`page-0001.table-grid.svg`, `page-0001.ocr-routes.svg`,
`page-0001.glyph-trace.jsonl`, `document.hocr.html`, and
`document.route-trace.json`; the corresponding records then include file
path, byte length, SHA256, page scope, layers, and provenance.

For host applications, prefer the neutral adapter command:

```bash
pdf-parser extract-adaptive \
  --input doc.pdf \
  --source-id external-system-id \
  --format artifact-jsonl \
  --debug-assets-dir review-assets
```

`source_id` is a caller-owned external identity, separate from the parser's
`document_id`. It is emitted on the manifest, artifacts, chunks, and provenance
envelopes so any pipeline can join records back to its own source table,
object-store key, or ingestion run.

Encrypted PDFs are opened with a supplied known password, not cracked:

```bash
pdf-parser extract encrypted.pdf --password "$PDF_PASSWORD"
pdf-parser extract-adaptive \
  --input encrypted.pdf \
  --source-id external-system-id \
  --password-file .pdf-password \
  --format artifact-jsonl
```

`--password-file` reads one local file and ignores trailing CR/LF bytes. Do not
use it with secret files you do not intend the worker process to read. The
parser records encryption/authentication metadata in the document manifest, but
never emits the password.

## Packaging For Host Apps

Use three integration modes, in this order:

1. **CLI subprocess**: recommended default for workers, research applications ingestion, and
   Cloud Run jobs. It is easiest to isolate, supervise, retry, and deploy:

   ```bash
   pdf-parser extract-adaptive \
     --input doc.pdf \
     --source-id external-system-id \
     --format artifact-jsonl
   pdf-parser extract-adaptive \
     --input doc.pdf \
     --source-id external-system-id \
     --format stream-jsonl
   ```

2. **C ABI**: use `zig build shared` and include `pdf_parser.h` for Python,
   Node, native, or other host bindings. The ABI returns the same versioned
   JSON/JSONL artifacts as allocated buffers; callers must release returned
   buffers with `pdf_parser_free_buffer(...)` or clear the full result with
   `pdf_parser_result_clear(...)`.

   ```c
   PdfParserAdaptiveOptions options = {
       .abi_version = PDF_PARSER_ABI_VERSION,
       .format = PDF_PARSER_FORMAT_ARTIFACT_JSONL,
       .input_path = "doc.pdf",
       .source_id = "external-system-id",
       .password = "known-password",
       .permissive = 1,
   };
   PdfParserAdaptiveResult result = {0};
   int status = pdf_parser_extract_adaptive_file(&options, &result);
   if (status == PDF_PARSER_STATUS_OK) {
       /* result.output/result.output_len is artifact JSONL */
   }
   pdf_parser_result_clear(&result);
   ```

   Python exposes the same surface as `zpdf.extract_adaptive(...,
   password="known-password")` or `password_file=".pdf-password"`. Node
   wrappers should prefer Node-API over direct V8 bindings for ABI stability,
   while research applications can continue using the subprocess path first.

3. **HTTP server**: useful for later long-running batch corpora or internal
   services. It is a stateless wrapper around the same adapter:

   ```bash
   pdf-parser serve --host 0.0.0.0 --port 8080
   curl -s http://localhost:8080/v1/extract-adaptive \
     -H 'content-type: application/json' \
     -d '{"input_path":"doc.pdf","source_id":"external-system-id","format":"stream-jsonl"}'
   ```

   Endpoints are `GET /healthz`, `GET /v1/capabilities`, and
   `POST /v1/extract-adaptive`. Cloud Run services should bind to
   `0.0.0.0:$PORT`; Cloud Run jobs should use the CLI subprocess mode and exit
   when the document or manifest finishes.

The specialist protocol keeps the Zig kernel deterministic while making local
specialists swappable. Route traces identify regions that need OCR, table,
formula, layout, or entity review; `specialist_request` records include the
page/region bbox, route reasons, signal scores, native spans/blocks, optional
crop/debug asset references, and provenance. By default the parser emits
requests and does not invoke table/formula/layout/entity specialists. Existing
Tesseract OCR output is represented as `specialist_response` and
`specialist_result` records when OCR runs. An explicitly enabled formula
specialist uses JSONL-over-stdin/stdout: one crop-backed request JSON object in,
one strictly linked response JSON object out. Table, layout, and entity
specialists remain request-only.

Optional specialist flags:

```bash
pdf-parser extract-adaptive \
  --input doc.pdf \
  --source-id external-system-id \
  --format artifact-jsonl \
  --emit-specialist-requests requests.jsonl \
  --specialist-config specialists.json
```

The minimal specialist config shape is a JSON object with optional `ocr`,
`table`, `formula`, `layout`, and `entity` entries. Formula entries may include
`enabled`, `executable`, `args`, `rasterizer_executable`, `crop_dpi`,
`crop_padding_points`, `crop_grayscale`, and `timeout_ms`. Formula invocation
is opt-in and model-neutral; no recognizer package is bundled. Memory-opened
documents, invalid geometry and unsupported rotations produce explicit
crop-stage outcomes. The development schema `0.18` maps declared quarter turns
through shared crop transforms; scan orientation detection is separate.

The document manifest is the top-level intelligence summary: input SHA256,
parser/schema versions, page count, encrypted/corrupt flags, route counts,
OCR/table/form/formula extraction counts, output artifact hashes or stream hash
slots, warnings/errors, and capability coverage. That makes it suitable as the
stable run record for general pipelines, not just this CLI.

For research applications-style ingestion, `stream-jsonl` maps naturally to durable
processing records: `document_manifest` as a manifest artifact,
`page_started`/`page_finished`/`document_finished` as status artifacts,
`span`/`block`/`table` as extracted text artifacts, `route_trace` and
`specialist_request` as metadata or OCR/specialist diagnostics,
`specialist_attempt`/`specialist_result` as returned specialist evidence, and `rag_chunk` as
chunk-index artifacts that can be queued for embeddings before the full
document finishes.

Table records are structured data artifacts: rows/cells, page-aware geometry,
logical multi-page table ids, continuation links, `rowspan`/`colspan`, roles
(`header`, `row_header`, `data`, `note`, `footer`), confidence, raw and
normalized text, deterministic numeric hints, and source span ids when
available. OCR remains local and deterministic: when a page or region is routed
to OCR, the adapter invokes Tesseract and reconciles the fresh OCR spans with
native PDF spans rather than replacing the whole page.

## Python

```python
import zpdf

with zpdf.Document("file.pdf") as doc:
    print(doc.page_count)

    # Single page
    text = doc.extract_page(0)

    # All pages (accuracy mode is default)
    all_text = doc.extract_all()

    # Fast mode (higher throughput, stream-order extraction)
    fast_text = doc.extract_all(mode="fast")

    # Page info
    info = doc.get_page_info(0)
    print(f"{info.width}x{info.height}")

# Zero-copy memory open (unsafe semantics for other language bindings)
with zpdf.Document.open_memory_unsafe(open("file.pdf", "rb").read()) as doc:
    print(doc.page_count)
```

Build the shared library first:
```bash
zig build -Doptimize=fast
PYTHONPATH=python python3 examples/basic.py
```
