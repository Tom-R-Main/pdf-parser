# Parser improvements for Editorial consumer and Research consumer

Local source review, 2026-10-10. Extends the [initial parser review](/Users/thomasmain/projects/pdf-parser/docs/local-reference-review-2026-10-09.md) with actual host workflows and newly added reference repositories.

**The highest-value shared capability is traceable extraction: every quotation, retrieved passage, and table value should lead back to a specific source run, page, and text/geometry range.** Fixing text loss remains first. After that, prioritize source mapping and host adoption of existing artifacts before adding more model complexity.

## What the hosts actually consume

### Editorial consumer

`extractPdfText` (`server/lib/pdf-extract.ts:250`) executes `pdf-parser extract` and returns a string, with a 45-second timeout and 25 MiB output limit. The surrounding code distinguishes process crashes, parser unavailability, resource limits, and document errors. Preserve those distinctions.

Verified workflows include:

- Chat attachments and general file extraction (`server/claude.ts:1261`): PDFs become text supplied as assistant context.
- Reference-document upload (`server/routes.ts:3676`): extracted text is persisted and sent into asynchronous chunk/embedding ingestion.
- Source-reference intake (`server/routes.ts:1184`): returns up to 50,000 characters and explicitly reports truncation.
- PDF transcript import (`server/routes.ts:6666`): feeds the existing transcript/editor pipeline.
- Document quote extraction (`server/domains/quotes/ingest.ts:453`): quote candidates carry character offsets against stored document text; offset mismatches are retained as review metadata. This downstream boundary is relevant to richer PDF locators, but not every PDF upload necessarily enters it.
- Quote-safety evaluation (`server/domains/quotes/safety.ts:62`): unverified/needs-review quotations remain a publishing gate. Better extraction must not automatically confer verification.

These paths chiefly need trustworthy readable text, explicit missing-page/region status, and source locators. Adaptive table or geometry improvements will not reach these callers until a host adapter consumes the richer output. Keep Newsroom/Civic and publication/team scopes in the host.

The build bootstrap (`scripts/ensure-pdf-parser.mjs:20`) currently pairs Zig 0.16.0 with parser commit `836ab436...`, checks the source archive hash, and builds for a baseline CPU. That pair is internally consistent. The parser project now selects Zig 0.17.0; updating Editorial consumer should update the accepted parser revision, compiler/archive identities, and runtime smoke evidence together. Changing only the compiler pin would not deliver the new parser behavior.

### Research consumer

`convertWithPdfParser` (`src/services/pdfConversionService.ts:547`) already consumes adaptive artifact JSONL. The protocol reader (`src/services/pdfParserProtocol.ts:228`) checks manifest/schema/source identity, input hash when supplied, per-record provenance, and specialist relationships. Supported schema families are currently `0.11.x` and `0.13.x`.

The conversion adapter (`src/services/pdfConversionService.ts:205`) retains the raw protocol and maps tables. The document-intelligence workflow (`src/services/documentIntelligenceExtractionService.ts:855`) persists the parser ledger and specialist artifacts. These are substantial integration assets, not missing infrastructure.

However, retrieval chunks flattened attachment text (`src/services/researchSourceIndexService.ts:683`), rather than directly consuming parser `rag_chunk`/block records. Page and section locators are copied from attachment-wide metadata. The reader already renders page/section locators (`web/src/uix/sourceReaderBlock.tsx:48`), so improving their accuracy has an existing product surface.

The table summary preserves raw/normalized text, numeric value, confidence, and source span IDs. It does not map all of the parser's cell bbox/role/rowspan/colspan or logical-table continuation fields. Those richer fields remain in the saved ledger; the opportunity is making them usable for evidence and analysis.

Conversion accepts nonempty Markdown without process/specialist errors (`src/services/pdfConversionService.ts:414`); rejection triggers the existing explicit Gemini fallback. A successful native conversion reports `imageCount: 0`, and the image extraction/upload path follows fallback. Thus native success does not by itself establish complete figure/image incorporation.

## A freshly reproduced host locator defect

Research consumer's `findOffset` (`src/services/researchSourceIndexService.ts:461`) searches whitespace-normalized text when exact matching fails, then returns normalized positions as raw-text positions. Its hybrid chunker normalizes whitespace (`src/utils/chunking.ts:40`), so the fallback is reachable for ordinary paragraph and table whitespace.

[The new probe](/Users/thomasmain/projects/pdf-parser/benchmark/eval/host_locator_probe.cjs) isolates and executes those actual functions using the host's installed TypeScript compiler API. It does not import configuration, database, or providers.

| Source text | Chunk text | Returned raw slice | Coverage |
| --- | --- | --- | --- |
| `A B C` | `A B C` | `A B C` | Exact control passes |
| `A   B C` | `A B C` | `A   B` | Omits `C` |
| Two newlines after `The office` | Single-space version | Omits the terminal period | Wrong raw end offset |
| `A 😀  B` | `A 😀 B` | `A 😀  ` | Omits `B` |

The evidence compares normalized raw slices with normalized chunks; expected whitespace differences alone are not counted as failures. [Results and source hashes](/Users/thomasmain/projects/pdf-parser/benchmark/eval/outputs/host-reference-review-2026-10-10/locator-probe.json) preserve the exact tested functions. This proves the function-level mapping defect, not a live database/UI failure.

## Ranked improvements by use case

| Priority | Shared improvement | Editorial consumer benefit | Research consumer benefit | Owning boundary |
| --- | --- | --- | --- | --- |
| P0 | Prevent legitimate same-MCID text from being deduplicated | Protect future adaptive adoption and tagged-document imports | Protect current adaptive ingestion from losing source lines | Reconciler |
| P1 | Explicit text views and reverse source maps | Verify quotes against the correct decoded source and highlight the PDF | Reliable citations, chunk offsets, source inspection | Parser contract + host mapping |
| P1 | Consume artifact geometry/chunks instead of flattening first | Structured document references alongside readable context | Page/section/table-aware retrieval using retained evidence | Host adapters; small parser linkage improvements |
| P1 | Per-page/region quality and bounded regional recovery | Scanned meeting packets, releases, PDF transcripts | Mixed exhibits, legal/financial documents, reduced whole-document fallback | Adaptive routing + host acceptance policy |
| P1/P2 | Exact table topology, numeric text, and continuation links | Budgets and financial source material without column scrambling | Investigative row/cell evidence across pages | Existing table grid + optional specialist + host mapping |
| P2 | Figure/crop references with captions and transforms | Explain where an upload contains unread diagrams/labels | Inspect source figures without treating native text as full visual coverage | Artifact/assets + host reader |
| P1 operational | Bounded output, cancellation, reproducible parser identity | Reliable uploads on the deployed host | Large-corpus ingestion without unbounded buffering or duplicate fallback work | Host process runner + native resource limits |

### 1. Fix loss and improve structural identity

The [unconditional MCID duplicate shortcut](/Users/thomasmain/projects/pdf-parser/src/reconcile.zig:749) still exists in the current source. The original reduction showed two distinct native lines collapsing to one adaptive span. The immediate fix should require equivalent content and placement rather than semantic group equality.

PDF Oxide adds a stronger follow-on reference: [`McidScope`](</Volumes/External SSD/referencerepos/pdf_oxide/src/structure/types.rs:8>) distinguishes page, Form XObject, and tiling-pattern namespaces. Its [structure traversal](</Volumes/External SSD/referencerepos/pdf_oxide/src/structure/traversal.rs:314>) carries those scoped references into ordered content. Borrow that distinction between structural grouping and extraction identity. Repeated drawing instances also need placement/instance evidence; `(scope, MCID)` alone is still not duplicate proof.

Both hosts need the text preserved before any quote, retrieval, or table feature can be trusted. Editorial consumer's present plain-text lane is not the adaptive reconciliation reduction, so do not report it as an observed Editorial consumer failure.

### 2. Reuse the parser's source mapping for quotation and retrieval locators

The parser already has [`SearchTextView`, transform flags, and reverse mapping runs](/Users/thomasmain/projects/pdf-parser/src/text_search.zig:1). The [glyph search source](/Users/thomasmain/projects/pdf-parser/src/root.zig:2452) attaches byte ranges to glyph geometry. Extend/reuse this machinery instead of creating a second normalization engine.

New reference evidence:

- MuPDF makes [ligature/whitespace preservation and dehyphenation explicit options](</Volumes/External SSD/referencerepos/mupdf/include/mupdf/fitz/structured-text.h:97>), and stores [character quads and paint flags](</Volumes/External SSD/referencerepos/mupdf/include/mupdf/fitz/structured-text.h:481>).
- pdfplumber's [`TextMap`](</Volumes/External SSD/referencerepos/pdfplumber/pdfplumber/utils/text.py:95>) maps output characters to source characters; synthetic layout whitespace can have no source character. Its [word extraction can retain constituent characters](</Volumes/External SSD/referencerepos/pdfplumber/pdfplumber/utils/text.py:683>).
- pypdfium2 explicitly [translates between PDFium character and text indices](</Volumes/External SSD/referencerepos/pypdfium2/src/pypdfium2/_helpers/textpage.py:88>), because inserted/excluded characters make them unequal. That implementation is a useful warning against assuming one string index space.

Proposed neutral contract: named text-view identity/hash, offset unit, transformation records, reverse ranges, page/span references, and optional precise geometry. Preserve decoded source text separately from readable/retrieval-normalized text and model suggestions. “Decoded source” is not a claim of byte-for-byte correspondence to the original PDF encoding.

Bind locators to the input hash, parser/config identity, saved ledger hash, and artifact IDs. Do not promise order-based IDs survive changed versions or routes. Translate Zig UTF-8 byte ranges into JavaScript UTF-16 ranges deliberately. Specify page index base, crop box, rotation, PDF-to-render transform, and coordinate units before highlighting.

Editorial consumer should keep its existing string API as a compatibility wrapper around a richer extraction result, and bind quote offsets to the exact persisted text view. Research consumer should fix `findOffset` with a reverse map or explicit unknown locator, then attach parser block/span evidence to retrieval chunks. Neither host should certify a quotation solely because OCR/model output is fluent.

Acceptance: round-trip locators through whitespace collapse, ligatures, dehyphenation, repeated identical quotes, non-BMP characters, ActualText, rotated pages, and OCR substitution. A transformed view must map to all relevant source ranges or admit ambiguity.

### 3. Adopt existing artifacts before enlarging the schema

The parser already emits [RAG chunk page ranges and source block IDs](/Users/thomasmain/projects/pdf-parser/src/schema.zig:1607), plus detailed table and provenance records. Its chunk `source_span_ids` are currently empty; derive span evidence through linked blocks or add tested range mappings rather than implying those arrays are complete.

First teach Research consumer's chunk adapter to use saved parser blocks/chunks as inputs, respecting the host's retrieval budget and overlap needs. Parser chunk sizes may not fit those budgets, so subdivision still needs source-range mapping. Preserve section ancestry, table rows/cell ownership, and page-local locators through embedding and reader presentation.

For Editorial consumer, add an opt-in richer PDF extraction result with text, page outcomes, locators, and structured tables. Use it at the shared extractor boundary so chat, reference ingestion, and transcript import do not each reinvent parsing. Keep full extracted evidence separate from the 50,000-character prompt/intake projection and its existing truncation flag.

Marker's [JSON renderer](</Volumes/External SSD/referencerepos/marker/marker/renderers/json.py:50>) combines block IDs, hierarchy, polygon/bbox, children, and images. Its [block metadata](</Volumes/External SSD/referencerepos/marker/marker/schema/blocks/base.py:17>) tracks previous text and model usage. Borrow the artifact organization; do not overwrite original evidence with generated HTML or edited text.

New fields need the parser's schema policy and coordinated Research consumer reader support. A new `0.14` family would currently be rejected. Editorial consumer's bootstrap must also advance its accepted parser pin. Keep all product-specific persistence and permission rules outside Zig.

### 4. Make recovery regional, bounded, and accountable

The initial review's visibility and vector-OCR gaps are particularly relevant to scanned civic packets, mixed PDFs, chart labels, and exhibits. A readable native page can still contain an unread scanned region.

Marker [reconstructs digital tables first, then OCRs unresolved crops](</Volumes/External SSD/referencerepos/marker/marker/processors/table.py:69>). Its [grid judge](</Volumes/External SSD/referencerepos/marker/marker/processors/table_recon.py:187>) scores multiple candidate grids. PDF Oxide's [routing function](</Volumes/External SSD/referencerepos/pdf_oxide/src/extractors/auto.rs:1379>) returns actual source/reason and distinguishes OCR unavailable from attempted OCR that failed or produced nothing. The latter is especially useful operationally; its page-level merge heuristics should not be copied as geometry-faithful deduplication.

MinerU's [PDF pipeline](</Volumes/External SSD/referencerepos/MinerU/mineru/backend/analysis/pdf/pipeline.py:40>) separates classification/native work from model lifecycle, and uses [bounded page windows](</Volumes/External SSD/referencerepos/MinerU/mineru/backend/analysis/pdf/window.py:80>). Its native foundation and significant table/render implementations delegate to DocVortex, which is not a separate checkout here. This review establishes the boundary/lifecycle pattern, not the behavior of that missing dependency.

Use deterministic page/region signals to retain reliable native evidence and request only unresolved regions. Record attempts, budgets, actual source, transforms, and unresolved coverage. Existing lifecycle/specialist records already provide much of the scaffolding; add missing acceptance/coverage information rather than inventing a parallel protocol.

Research consumer could eventually recover selected regions before invoking its existing whole-document Gemini fallback. That is a proposed acceptance-policy change, not permission to accept incomplete evidence. Editorial consumer could route local OCR through the richer extractor while retaining its established generative provider boundary. No new vendor/model is selected here.

Acceptance: exact page enumeration; distinguish verified blank, no selectable text, OCR unavailable, low-quality recognition, and clipped/nonpainting text. An unresolved page must be visible to both the reader and retrieval policy. Never turn process completion into a coverage claim.

### 5. Preserve table facts and make geometry inspectable

For budget/earnings source material and investigations, the useful target is a traceable fact such as `(row label, period/header, raw value, units/footnote, page, cell)`. Markdown appearance or a plausible aggregate alone is insufficient.

pdfplumber offers a concrete deterministic comparison: [snap/join edges](</Volumes/External SSD/referencerepos/pdfplumber/pdfplumber/table.py:21>), then [intersections, cells, and table groups](</Volumes/External SSD/referencerepos/pdfplumber/pdfplumber/table.py:586>), with [debug overlays](</Volumes/External SSD/referencerepos/pdfplumber/pdfplumber/display.py:339>). The parser already has native table grids and overlays; use these references to design harder broken-rule/borderless controls and inspect disagreements, not to add a second table kernel.

Map existing cell geometry, roles, spans, raw numbers, continuation IDs, and source spans into Research consumer's usable artifacts. Use explicit block/table linkage after reconciliation so the host no longer needs to infer replacements from pre-reconciliation indices. Preserve compatibility while adding that relationship.

Keep numeric parse hints subordinate to raw strings. Parenthesized negatives, blanks versus zero, scaled units, footnotes, and repeated headers deserve exact assertions. Table candidates can be evaluated with topology metrics plus exact cell/number/source-coverage metrics; do not infer confidence calibration from Marker judge constants.

Figure crops and captions are another useful evidence surface. Emit/reference materialized source crops with hash, page geometry, transform, and owner IDs, allowing the host to show chart/table/signature regions. Separate visual descriptions from extracted source text. Use existing render/debug adapters before considering a model for interpretation.

### 6. Bound the host and native work together

Research consumer's process runner (`src/services/pdfConversionService.ts:331`) caps stderr but accumulates stdout without a byte limit. Editorial consumer already caps text output. For large artifact streams, add a host output budget or incremental JSONL persistence, cancellation, and deterministic final acceptance. Persisting useful partial artifacts should not mark a canceled run complete.

Ghostty's [limited allocator](</Volumes/External SSD/referencerepos/ghostty/src/datastruct/limited_allocator.zig:4>) explicitly limits each allocation request, not total live memory. Borrow that precision; a parser budget needs separate limits for decoded stream size, aggregate retained memory, and host serialized output. MinerU's windowing is a separate control on work retained at once. Do not confuse any of these with a process-wide guarantee.

TigerBeetle's [seeded fault simulator](</Volumes/External SSD/referencerepos/tigerbeetle/src/vopr.zig:126>) makes failures reproducible. Apply the principle to parser/host fault tests: malformed JSONL halfway through a page, output limits, process death, interrupted rasterization, retries, and storage failures, with replayable seeds and cleanup assertions. There is no reason to import its database architecture.

Valgrind's [custom allocation annotations](</Volumes/External SSD/referencerepos/valgrind/include/valgrind.h.in:7479>) help tools see allocation boundaries. Keep the parser's existing diagnostics as a separate validation lane; a reference checkout or counter returning zero is not itself proof of a full Memcheck run. No new memory/performance qualification was run in this review.

## Reference identities and adoption limits

| Newly inventoried reference | Local HEAD | Primary lesson |
| --- | --- | --- |
| MinerU | `31e4e3d0a54e5a82d169bdd81b2f3eddb652bb27` | Native/model separation, windows, cleanup |
| Marker | `e7c67f1d239ea6a805cbf4ed6c6b2056d435e22d` | Block hierarchy, native table judge, regional fallback |
| MuPDF | `200426aee5b4c19fb60a3d0787f0343524ac218f` | Explicit text transforms, character quads, paint evidence |
| PDF Oxide | `ad49c4cb3638dc950a29350ef882161372fde473` | Scoped MCIDs and honest fallback reasons |
| pdfplumber | `4c64b92d5caccd71c645e98e0fabb0c4dba7ff45` | Output-to-character maps, table construction/debugging |
| pypdfium2 | `062c481370902ada05f9b6635a8381755a898eef` | Index translation and optional render/geometry oracle |
| Ghostty | `1da3ac43bef626ec1155c366c1960cb0f4f74d1f` | Precise allocator limits and diagnostics |
| TigerBeetle | `c95d7a53a3d044741409b03b2f334a8ed033fa3c` | Reproducible fault injection |
| Valgrind | `0ff27aab0831786c7f419e73a2b5217cbbcc792d` | Allocation visibility for memory tooling |

For actual dependency adoption, distinguish source and model terms: [pdfplumber is MIT](</Volumes/External SSD/referencerepos/pdfplumber/LICENSE.txt>), [PDF Oxide declares MIT/Apache-2.0](</Volumes/External SSD/referencerepos/pdf_oxide/Cargo.toml:93>), and [pypdfium2/PDFium distributions have component attribution requirements](</Volumes/External SSD/referencerepos/pypdfium2/README.md:815>). [MuPDF supplies AGPL/commercial terms](</Volumes/External SSD/referencerepos/mupdf/README:16>); [Marker separates code from model-weight terms](</Volumes/External SSD/referencerepos/marker/README.md:65>); [MinerU adds online-service attribution and commercial thresholds](</Volumes/External SSD/referencerepos/MinerU/LICENSE.md:1>). This is local license inventory, not an adoption decision or legal clearance. Source patterns can guide an independently implemented design without selecting any of these as a production dependency.

## Delivery and acceptance sequence

1. **Correctness foundation:** fix MCID data loss, fix the host locator reduction, and define text-view/offset/coordinate semantics. Keep parser and host changes independently reviewable.
2. **Use existing evidence:** consume parser block/chunk/table references in Research consumer and introduce Editorial consumer's compatible richer extraction result. Preserve original decoded evidence through prompt projections and embeddings.
3. **Quality and resource controls:** expose page/region acceptance, cap/incrementally persist artifact output, and evaluate regional OCR on mixed documents before changing fallback policy.
4. **Richer document semantics:** test table linkage/continuations, figure crops/captions, and section ancestry; maintain the previous reading-order experiment's frozen stop rule.

Build a small source-grounded acceptance matrix from public/redacted newsroom releases, transcripts, civic packets, legal/financial reports, mixed scans, and rotated/Unicode documents. These are recommended fixture classes; no private production documents were read here. Score each host's actual lane separately: quote slice/highlight correctness; page and section locator correctness; exact numbers/row relationships; unresolved-coverage reporting; cancellation/output limits; and deterministic replay. Keep native, external readable fallback, OCR, and generated interpretation distinguishable.

## Evidence boundary

Inspected parser HEAD `1ca410286d0ee80b645aa58f437a53c35829f898` with selected Zig 0.17.0, Editorial consumer HEAD `b00afca769d940b6a625bb47131d5072a00d225d`, and Research consumer HEAD `5ef8719b66f6a363891013bdb99e609f380bf4ab`. Research consumer had 36 tracked working-tree changes during inspection, so findings describe the local checkout rather than an assertion about that commit or deployed behavior. The locator probe records exact file hashes. The new reference checkouts had no tracked changes.

Fresh execution was limited to the isolated four-case host locator probe and harness syntax checks. The initial parser defects/2,886-test baseline belong to the prior dated review; the retained MCID shortcut was rechecked in current source. No host runtime, database, paid inference, specialist model, full suite, or performance benchmark ran in this extension. No production code, host files, reference checkouts, compiler pins, or deployments were changed. Added research files and ignored evidence only.

Reproduce the locator evidence with the already-installed host compiler API:

```sh
node benchmark/eval/host_locator_probe.cjs /path/to/consumer path/to/chunking.ts path/to/indexing.ts
```
