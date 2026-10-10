# Parser, Research consumer, and Editorial consumer implementation plan

Status: phases 0/1 implemented and locally verified; reconciled table links, bounded streaming and recovery assessments implemented in pdf-parser, host adoption pending, 2026-10-10. All current writes are restricted to pdf-parser: planned host edits below remain adoption instructions. Based on the [local reference review](local-reference-review-2026-10-09.md) and [host use-case review](host-usecase-reference-review-2026-10-10.md). Paint/clipping evidence, regional OCR crops, richer hierarchy/figures and host rollout remain planned.

## Delivery order and ownership

| Phase | pdf-parser owns | Research consumer owns | Editorial consumer owns | Dependency / exit gate |
| --- | --- | --- | --- | --- |
| 0: protect evidence | Remove MCID-only duplicate identity; span preservation and duplicate-provenance regressions | Translate normalized chunk matches back to raw UTF-16 source offsets; service persistence regressions | No immediate code change; current plain-text lane does not use adaptive reconciliation | Independent patches; red-to-green tests and fresh parser build |
| 1: source locator contract | Reuse search text views and reverse maps; populate chunk span references; document text and geometry units | Preserve source text identity; carry chunk origin ranges through composition; consume parser chunk/block references | Introduce a rich extraction result behind the existing string API; preserve source text separately from truncated prompt projections | Versioned artifact contract, Unicode/rotation and overlapping-chunk fixtures |
| 2: host adoption and work bounds | Deterministic run identity and stream lifecycle; exercise cancellation/resource-limit fixtures | Retain table geometry/continuation fields; bound process stdout and cancellation; reader links to exact evidence | Update parser revision/compiler/archive pins together; route reference/transcript consumers through rich results | Both host readers pass contract fixtures and process failure tests |
| 3: coverage and regional recovery | Per-page/region quality states; paint/clipping evidence; bounded regional OCR via existing specialist protocol | Persist unresolved coverage; apply explicit acceptance policy before fallback/retrieval | Surface unresolved pages in source intake and quote review | Mixed scan/native controls; no success-as-completeness inference |
| 4: richer document evidence | Explicit reconciled table/block linkage, continuation tests, section ancestry and figure/crop references | Map row/cell/figure locators into document intelligence and source reader | Add table/source inspection for civic packets and financial references | Exact values, topology, crop identity and source coverage holdouts |

Implement phase 0 first. Agree on phase 1 contracts before changing either host's extraction defaults. Phase 2 output limits can proceed independently of new schema fields; coverage and richer evidence depend on the source locator contract. Model/vendor selection is a separate decision.

## Phase 0: two bounded correctness fixes

**Parser files:** `src/reconcile.zig`, `src/testpdf.zig`, `src/integration_test.zig`, plus ignored CLI reduction output from `benchmark/eval/reference_review_probes.py`.

- An MCID groups content; it does not prove two spans are duplicates. Require the existing normalized-text equality and same-page geometry overlap for all duplicates.
- Regress distinct text with a shared MCID even at identical placement, repeated text at different placements, and genuine native/OCR duplicates with retained source masks/counts.
- Run the narrow MCID tests before and after the patch, the full Zig test/build gates, and the actual two-line tagged-PDF CLI reduction. Keep public schema 0.13.0 unchanged.

**Research consumer files:** `src/services/researchSourceIndexService.ts` and its existing test file.

- `startOffset`/`endOffset` remain half-open JavaScript UTF-16 offsets into the original persisted source text. Normalize only for matching, reverse-map boundaries through whitespace runs, and advance the cursor in raw source coordinates.
- Assert the values passed into chunk persistence using the real hybrid chunker for ordinary cases: exact text, repeated spaces, paragraph breaks, surrogate pairs, leading/trailing whitespace, tabs/CRLF/nonbreaking spaces. Controlled chunk output covers repeated occurrences and unavailable matches.
- Unmatched text retains null offsets. Preserve RLS, schema, chunk hashes/identities, embedding semantics, and forward cursor policy. Overlapping chunk origin tracking is phase 1; do not fabricate positions when that policy cannot resolve a chunk.
- Existing incorrect persisted offsets are not repaired automatically. Explicit rechunking updates matching chunk identities through the existing upsert; a separately scoped repair must validate source hashes and avoid triggering unintended embedding work.
- Run the service Jest lane and installed compiler's typecheck. Report Nx checkout collisions separately if they prevent Nx orchestration; do not modify unrelated checkouts to run this fix.

Acceptance: both defect tests demonstrably fail on the original implementation and pass after the patch; true duplicates still merge; stored ranges cover the complete normalized chunk. These are local code/CLI/service-mock checks, not a database or deployed UI acceptance claim.

## Phase 1: preserve text identity and exact source locations

**Parser:** extend `src/text_search.zig`, `src/schema.zig`, `src/reconcile.zig`, `src/specialist_protocol.zig`, and `docs/output-schema.md`. Reuse the current reverse map rather than building another normalization engine. Populate `rag_chunk.source_span_ids` from owning blocks and spans. Specify source/input hash, decoded/view text identity, normalization flags, UTF-8 byte ranges, page indexing, and PDF-point geometry with rotation/crop transforms. Scope structural MCIDs by page/content stream or Form instance when structural identity is exposed; never restore MCID-only deduplication.

**Research consumer:** update `researchSourceIndexService.ts`, `utils/chunking.ts`, `services/pdfParserProtocol.ts`, `services/pdfConversionService.ts`, and `services/documentIntelligenceExtractionService.ts`. Carry origin ranges from structural/semantic chunk composition, including overlap, instead of rediscovering repeated passages by text search. Convert UTF-8 boundaries to UTF-16 explicitly at the host boundary; reject invalid/out-of-range identities. Prefer parser chunk/block locators for PDF attachments, retaining the text-only chunk path for other sources.

**Editorial consumer:** extend `server/lib/pdf-extract.ts` with a rich extraction API returning text, source/run identity, page/block/span locators and coverage. Keep `extractPdfText` as a compatibility projection. Update PDF consumers in `server/claude.ts`, `server/routes.ts`, and `server/domains/quotes/ingest.ts` to retain source evidence. Prompt limits and stored-document limits must be separate projections with explicit truncation; validate quote offsets against the exact retained text view. Parser evidence does not automatically verify a quotation.

Gate: a shared small public/redacted fixture set covers ligatures, repeated phrases, collapsed whitespace, Unicode beyond BMP, overlapping chunks, rotated/cropped pages, and synthetic whitespace with no glyph evidence. Each returned range round-trips to the declared text view and source geometry; wrong input/text-view identities fail explicitly. Additive public fields require the documented schema increment and reader compatibility tests before host activation.

Phase 1 delivery is documented in [host adapters](host-adapters.md) and the
[0.14 text/source-map contract](output-schema.md). Shared modules carry origins
through overlapping composition, validate rich extraction, convert byte ranges
to UTF-16 and link chunks to page/span evidence. The native contract preserves
exact identity text rather than introducing another normalization engine.
Span geometry is explicit; viewer transforms and structural MCID namespaces
are not newly exposed. Host database/UI adoption, deployments and backfills
remain pending; neither host checkout was edited in phase 1.

## Phase 2: adopt existing artifacts and bound execution

**Research consumer:** map existing table cell bbox, role, row/column spans, source spans and logical continuation IDs in `pdfConversionService.ts`; retain raw values alongside parsed hints. Add output byte budgets to its subprocess runner, then incremental JSONL persistence where warranted. Cancellation/timeout/oversized stdout must terminate and clean up the process and prevent a complete-run receipt. Retain current explicit fallback behavior until coverage policy is separately qualified. Test malformed/truncated JSONL, child exit, huge stdout, late output after cancellation and idempotent retries.

**Editorial consumer:** change `scripts/ensure-pdf-parser.mjs` only with a tested parser revision + Zig 0.17 + archive identities as a pair. Preserve baseline CPU and runtime smoke checks. Expand `server/test/pdf-extract.test.ts`, reference intake tests and transcript/quote tests for both old string and new rich result consumers. Keep the current timeout/output bound and failure distinctions. Network archive fetching and deployment are separate authorized steps, not part of the current local patch.

**Parser:** extend stream lifecycle and resource fixtures in `src/stream.zig`, native limit owners, `src/main.zig` and integration tests only where a missing limit is demonstrated. Distinguish decoded-stream, retained-memory and serialized-output budgets. Record parser build identity, options, specialist versions and terminal state in a deterministic receipt.

Gate: no unbounded host accumulation; no partial/canceled run accepted as complete; both hosts retain stable input/artifact identity and can reproduce a locator. Run actual host tests and neutral parser JSONL fixtures before switching defaults. Roll back host adoption through the compatibility projection/accepted reader family; retain evidence from unsuccessful runs as incomplete.

## Phase 3: coverage and regional recovery

**Parser:** propagate text rendering mode, clipping/paint evidence and page completeness through native spans, layout, adaptive routing and schema. Distinguish verified blank, no selectable text, OCR unavailable/failed, low recognition quality, and unresolved region. Route bounded crops through existing OCR/specialist adapters outside the Zig kernel. Do not interpret outlined lettering as a verified blank page.

**Hosts:** persist those states in Research consumer's parser ledger/reader and Editorial consumer's extraction result/intake review. Decide when to accept partial text, withhold retrieval, request review or invoke existing fallback. Keep native text, OCR and generated interpretations separately attributable.

Gate: deterministic fixtures for blank pages, outlined glyphs, invisible OCR, clipping, scans mixed with native text, rotation, unavailable rasterizer/OCR, and partial specialist failure. Assert exact page enumeration and unresolved-region visibility. Use separate new held-out documents; do not retune the earlier failed reading-order holdout or promote its diagnostic graph.

## Phase 4: tables, hierarchy and figures

**Parser:** explicit post-reconciliation block/table relationships; tested cross-page continuation and section ancestry; source crop/figure records with hash, owner, bbox and transform. Extend existing table grid/debug tooling with broken-rule and borderless reductions informed by local pdfplumber patterns. Keep raw financial strings authoritative over numeric hints.

**Research consumer:** expose cell/header/page relationships through document intelligence and `web/src/uix/sourceReaderBlock.tsx`; retain row labels, periods, units and footnotes. Show figures even when native text conversion succeeds.

**Editorial consumer:** add source/table inspection within edition-scoped reference workflows, carrying existing quote-safety and publishing gates through richer evidence.

Gate: exact assertions for parentheses negatives, blank versus zero, scale/units, footnotes, merged cells and repeated headers; inspect crop identity and geometry round-trips. Measure topology and source coverage separately from readable Markdown. Evaluate interpretation models only after these deterministic controls.

## Validation and rollout discipline

- Parser: selected Zig 0.17; narrow regressions, `zig fmt --check`, `zig build test --summary all`, `zig build --summary all`; adaptive corpus eval when behavior touches routing/layout/schema. Fast-build benchmark lanes qualify any later performance claim.
- Research consumer: installed package Jest lanes plus authoritative TypeScript 7 compiler; Nx targets where its project graph resolves. Protocol/process tests before any changed fallback or ingestion default; reader tests before locator UI claims.
- Editorial consumer: existing Vitest PDF/reference/quote/transcript lanes plus typecheck; paired toolchain bootstrap and deployed runtime/browser checks are later gates.
- Track each phase's source tests, runtime artifacts, deployed revision and product acceptance separately. Preserve unrelated dirty files; no raw private/large PDFs in Git. No deployment, paid inference, archive fetch or bulk backfill is included in phase 0.

## Phase 0 execution evidence

- Red: the original reconciler failed both preservation tests (expected two spans, got one), while the true duplicate control passed. The original host service failed six of the first seven added cases; its exact-text control passed.
- Green: all three focused MCID unit tests passed. A generated PDF integration test now verifies both lines, MCID preservation, Markdown order, artifact JSONL/provenance and retrieval chunk coverage.
- Parser gates: Zig 0.17.0; tracked Zig files pass formatting; `zig build test --summary all` passes all 62 steps after the final integration regression (2,101 tests executed in that run, other test steps cached). `zig build --summary all` passes all 12 steps.
- Host gates: research indexing, structural chunking and hybrid chunking Jest lanes pass all 33 tests across three suites; package typecheck passes with the authoritative TypeScript 7.0.2 compiler. Whitespace variants select source occurrences in order; an unavailable match retains null offsets without rewinding the raw cursor.
- Actual CLI evidence: [MCID reduction](../benchmark/eval/outputs/phase-0-fixes-2026-10-10/mcid-probe.json) retains `FIRST` and `SECOND` in native text, adaptive spans and chunks, with zero false duplicates. [Host function probe](../benchmark/eval/outputs/phase-0-fixes-2026-10-10/locator-probe.json) now covers the full source slice in all four original cases. These local evidence files are ignored.
- Nx orchestration was attempted but its graph failed on pre-existing duplicate project definitions in `.context` checkouts. Used the installed package Jest/typecheck scripts; no workspace cleanup or install was needed.
- Public schema and host database schema are unchanged. Existing persisted locators are untouched. Editorial consumer is planned only; no production host runtime/database/UI test, deployment, backfill, paid inference or performance qualification was performed.

## Phase 1 execution evidence

- All phase 1 writes are in pdf-parser. Host code was read to define adoption requirements; neither Editorial consumer nor Research consumer was edited.
- Schema 0.14.0 adds exact-text view hashes and half-open UTF-8 source maps. Construction records span byte origins, including repeated Unicode text. Chunk source-span ids and streaming map ids resolve to the emitted document-global records; synthetic separators have no span geometry.
- New neutral Node modules expose overlap-aware origins, validated rich extraction, separate prompt projection and hash-bound source-range lookup. Typed declarations pass the installed TypeScript 7 strict no-emit check; no dependency installation was needed.
- Node checks pass 9 chunk-origin tests, 57 extraction/protocol/process tests, and 2 actual CLI integration tests. Both real integration tests executed rather than skipped: generated repeated same-MCID lines across two pages, and checked-in complex financial artifacts.
- Zig formatting and `zig build test --summary all` pass all 62 steps (2,183 tests executed in the last full run, remaining steps cached). The final build passes all 12 steps, including shared-library artifacts.
- The adaptive corpus evaluation completed with local Tesseract/Poppler and the checked-in manifest. This is extraction evidence, not a comparative performance claim or a new page-coverage qualification.
- Actual CLI probes also consumed forms, rotated native text and a mixed native/scan fixture with OCR disabled. Their rich results keep page coverage unverified. Financial fixtures retain legacy specialist labels and report unresolved table/block provenance separately; those legacy references do not contribute to source locators.
- No host ingestion, database migration, corpus backfill, runtime switch, deployment or publishing occurred. Host wiring and explicit 0.14 reader acceptance remain adoption work outside this authorized write scope.

## Review and remediation

Observed on the current working tree: independent review reproduced weak source
identity validation and unbounded waits for wrapper descendants. Both now have
passing regressions; POSIX termination owns the process group and closes pipes,
and extraction validates the exact source id it supplied. A native allocation
failure regression also exposed detached block/chunk buffers; error cleanup now
passes all injected allocation failures. Explicit consumer names and repository
paths were removed from the added code and documentation.

Observed checks: 73 JavaScript tests passed, both real CLI integrations executed,
strict declaration typecheck passed, Zig formatting passed, and the full Zig
test/build targets passed (62/62 and 12/12 steps). A source/binary-hash-bound
[verification receipt](../benchmark/eval/outputs/phase-1-review-2026-10-10/receipt.json)
retains the final public adapter/CLI readback. Windows process-tree cleanup and
consumer runtime adoption remain unverified.

## Parser capability continuation

Schema 0.15.0 implements three parser-side units from the later phases:

- Authoritative reconciled span/table/cell owners use source-span membership,
  including document-global streaming ids. Numeric layout compatibility fields
  remain available; the reader validates exact ownership and same-page scope.
- Native streaming caps aggregate output and adaptive page allocations. A new
  incremental page adapter applies page/record/count limits and serial callback
  backpressure. Budget, cancellation, process and callback failures cannot
  produce an accepted complete receipt.
- Page/region assessments report retained text and unresolved recovery. Selected
  OCR/formula output must intersect the assessed region; failed or disabled
  recovery remains visible alongside native text. Completeness stays unverified.

Regressions exercise forged ownership, contradictory coverage, later-page source
locators, actual native allocation exhaustion, mixed native/scan extraction and
stream failure paths. The previous phase receipts describe historical hashes;
the continuation receipt records the current source/binary and gate results.

Observed checks: all 128 JavaScript tests pass without skips, strict declaration
typechecking and Zig formatting pass, and native test/build targets pass all
62/62 and 12/12 steps. All 36 checked-in corpus documents pass both public batch
and streaming readers with OCR disabled. The adaptive evaluation also completes
all 36 cases with local OCR enabled. A mixed native/scan readback changes from
`recovery_required` to `recovered` when OCR is enabled, while keeping visual
completeness unverified. These runs qualify the exercised contracts, not
universal extraction accuracy or performance.

Independent read-only review found forged span ownership, cross-page cells and
out-of-scope/contradictory coverage acceptance. All are rejected after remediation
and covered by permanent regressions. The hash-bound
[continuation receipt](../benchmark/eval/outputs/parser-capabilities-2026-10-10/receipt.json)
retains the gates, corpus results, actual OCR outcome and limitations.

Next parser work is paint/clipping provenance and bounded regional OCR crops,
with outlined-lettering, invisible-text, clipped-text and mixed-region controls.
Host activation remains a separate adoption step with reader/persistence tests.
Table topology, cross-page continuation, hierarchy and figures need their own
holdouts; exact reconciled links alone do not qualify those capabilities.

Inferred next priority from the financial fixture's three unresolved legacy
table/block references: implement exact reconciled table linkage with additive
fields, then bound streaming/retained memory, then expose page/region coverage.
These are recommendations; no subsequent phase was started by this review.
