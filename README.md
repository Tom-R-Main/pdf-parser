# pdf-parser

Extract text, tables, and form values from PDFs with a Zig parser. The output
keeps page geometry and source references, so an ingestion pipeline can show
where a result came from.

The native extraction path is deterministic. Adaptive extraction adds layout,
table reconstruction, routing to local OCR, and versioned JSON/JSONL records.
Use the CLI as a subprocess when you need to isolate and supervise each run.

This is a capable pre-1.0 parser. The current development build is `0.4.0-dev`
and its adaptive schema is `0.20.0`. Check [the changelog](CHANGELOG.md) before
updating a pinned parser or schema version.

## Build and extract

Use **Zig 0.17.0**, as pinned in [.zig-version](.zig-version). Run these commands
from the repository root:

```sh
zig version
zig build --summary all
./zig-out/bin/pdf-parser extract-adaptive \
  --input benchmark/eval/corpus/clean_born_digital/clean-native.pdf \
  --format artifact-jsonl --no-ocr
```

The example uses a small checked-in PDF. It writes a document manifest followed
by records for extracted text, layout blocks, routes, and retrieval chunks.
The manifest includes the parser and schema versions, input hash, page count,
and artifact counts.

To extract your own PDF and keep an external source identity with every record:

```sh
./zig-out/bin/pdf-parser extract-adaptive \
  --input document.pdf --source-id source-123 \
  --format artifact-jsonl --no-ocr > document.jsonl
```

`--no-ocr` disables fresh OCR. To recognize scans and routed image regions,
install Tesseract and Poppler's `pdftoppm`, then omit that flag. The native
parser can run without those OCR tools. Readable extraction may also use
`pdftotext` when the native layout quality check fails; such text retains
`poppler_text` provenance.

## Choose an output

| Task | Command or format | Result |
| --- | --- | --- |
| Ingest a complete document | `extract-adaptive --format artifact-jsonl` | Manifest-first batch records |
| Persist pages as they finish | `extract-adaptive --format stream-jsonl` | Page lifecycle events and artifacts |
| Read native text | `extract document.pdf` | Text with the default accuracy path |
| Use content-stream order | `extract --fast document.pdf` | Native text with fewer reconstruction stages |
| Find a phrase | `search "annual revenue" document.pdf` | Normalized matches with source information |
| Inspect routing | `inspect complexity document.pdf --format json` | Page and region decisions |

Commands in the table use `./zig-out/bin/pdf-parser`. Run that binary with
`--help` for options, or see [usage and integration](docs/usage.md) for examples.

Accept a complete stream only after a valid `document_finished` record and a
successful process exit. Receiving a page is useful partial work; it does not
prove that the rest of the document finished.

## Keep the evidence

Adaptive records carry page indices, bounding boxes, source kinds, confidence,
and provenance links. Blocks and chunks have hashed text views and exact UTF-8
source maps. Synthetic spaces have no invented source glyph.

Tables retain rows, cells, raw values, numeric hints, roles, spans, and source
ownership. Section annotations use matched bookmarks, numbering, then heading
style; ambiguous matches abstain. Cross-page table continuation uses one
bounded policy in both output formats.

For finer quote geometry and a decoded-stream limit:

```sh
./zig-out/bin/pdf-parser extract-adaptive \
  --input document.pdf --format artifact-jsonl --no-ocr \
  --include-glyph-geometry --max-decoded-stream-bytes 16777216
```

Geometry is optional. A ligature remains one source glyph, and an ActualText
replacement retains group bounds without invented character boxes. Coordinates
remain in raw PDF user space; use the page transforms when drawing highlights.
The [output schema](docs/output-schema.md) defines units, ranges, precision,
record ordering, and compatibility rules.

## Integrate it

The CLI/JSONL boundary is the default integration surface. The repository also
includes a C ABI, Python bindings, JavaScript adapters, a stateless HTTP wrapper,
and a WebAssembly build.

The JavaScript adapters use a host-selected executable, validate records, and
retain source positions. Node 22 or newer is required:

```js
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { extractPdfDocument } from './integrations/javascript/index.mjs';

const document = await extractPdfDocument(await readFile('document.pdf'), {
  binaryPath: resolve('zig-out/bin/pdf-parser'),
  includeGlyphGeometry: true,
  maxDecodedStreamBytes: 16 * 1024 * 1024,
});
console.log(document.blocks.map(block => block.text).join('\n\n'));
```

See [host adapters](docs/host-adapters.md) for streaming, cancellation, budgets,
UTF-16 locators, and prompt projections. Use `zig build shared` for the C ABI;
its header is [include/pdf_parser.h](include/pdf_parser.h). The Python package
keeps the name `zpdf`; [its guide](python/README.md) covers installation and use.

OCR and formula recognition run outside the PDF kernel. Tesseract OCR is local;
formula recognition requires an explicitly configured specialist. Table,
layout, and entity specialist families currently emit requests. A protocol
record alone does not mean a specialist has run.

## Limits that matter

- Text availability and successful OCR do not prove complete page coverage.
  Recovery records keep unresolved regions and failed attempts visible.
- Table continuation is heuristic. Unrelated tables can share a header and
  geometry; partial headers and page gaps remain separate.
- Section hierarchy and fine quote geometry have deterministic regression
  controls. Broad real-document hierarchy and visual-highlight accuracy remain
  unqualified. The experimental reading-order graph is diagnostic; legacy order
  remains the default.
- `--max-decoded-stream-bytes` bounds each filter or predictor stage, not total
  retained memory. Streaming also supports `--max-output-bytes` and
  `--max-page-memory-bytes`; document caches, allocator overhead, and subprocess
  memory are outside the page budget.
- Known-password decryption is supported. Image render completeness for formats
  such as JBIG2 and JPEG2000 depends on an external rasterizer when OCR is used.

## Test and measure

```sh
zig build test --summary all
zig build shared wasm --summary all
node --test --test-concurrency=1 integrations/javascript/*.test.mjs
python3 benchmark/eval/section_safety.py --output benchmark/eval/outputs/section-safety-run
```

Choose a fresh output directory for each safety run. The
[evaluation guide](benchmark/eval/README.md) covers the small correctness corpus,
frozen table and reading-order controls, and regression gates. The
[benchmarking guide](docs/benchmarking.md) separates native, adaptive, streaming,
and OCR lanes. Use fast builds and repeatable scorecards for performance claims;
debug timings and one document do not establish a general ranking.

## Documentation

- [Usage and integration](docs/usage.md): CLI, Zig, C, Python, and server examples.
- [Output schema](docs/output-schema.md): public records and compatibility policy.
- [JavaScript host adapters](docs/host-adapters.md): extraction and source locators.
- [Architecture](docs/architecture.md): kernel, adaptive pipeline, and public boundaries.
- [Evaluation](benchmark/eval/README.md) and [memory checks](docs/memory-checks.md).
- [Changelog](CHANGELOG.md) and [0.20 implementation evidence](docs/parser-improvements-2026-10-31.md).

## License

MIT for new implementation work. This project began from `Lulzx/zpdf` at
`5eba7ade759d32b0d425eb905c17106b484dee30`, released under CC0-1.0. See
[NOTICE.md](NOTICE.md) and [the original license](LICENSES/CC0-1.0.txt).
