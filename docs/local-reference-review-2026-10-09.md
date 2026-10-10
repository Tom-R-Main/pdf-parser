# Local reference review: improving extraction fidelity

Reviewed 2026-10-09 against `/Volumes/External SSD/referencerepos`.

Follow-up: [Editorial consumer and Research consumer use cases plus newly added local references](/Users/thomasmain/projects/pdf-parser/docs/host-usecase-reference-review-2026-10-10.md), reviewed 2026-10-10 against the current Zig 0.17 checkout. The build/test evidence below remains the original dated Zig 0.16 baseline.

The strongest next step is to preserve more of the PDF's evidence through extraction and reconciliation. The parser already has a substantial kernel, glyph geometry, native layout, table grids, adaptive routing, provenance, and public artifact boundaries. Preserve that architecture. The local references suggest specific improvements at those boundaries, rather than replacing the kernel or introducing a general model dependency.

**First fix the confirmed marked-content data loss. Then improve visibility, outlined-text routing, and line/word boundaries.** Reading-order, table specialists, and semantic heading hierarchy are worthwhile follow-on experiments, with explicit acceptance gates.

## Scope and source identities

I inventoried the local reference directory and focused on its document-processing implementations. Docling and Docling Parse provided the closest extraction and layout comparisons; PaddleOCR provided specialist contracts and table evaluation; LibreOffice provided an independent graphics-state implementation; Docjev provided host completeness and corpus practices. Other checkouts in the directory largely concern unrelated applications, agents, infrastructure, and UI.

| Checkout | Local HEAD | Role in this review |
| --- | --- | --- |
| pdf-parser | `836ab4360b7c31d72f519ab2be82d7268c5f4852` | Current implementation and fresh probes |
| docling | `d0f55469c56d38d93ed47049b8c9d17f6785e94b` | Visibility, selective OCR, layout, tables, quality |
| docling-parse | `e0e678ce182a8a9b1b143e50251b51048ad767e4` | Rotated cell contraction, spacing, clipping |
| PaddleOCR | `dab3fe35379033fdcb2d0e9572fac0b36c9a9ebf` | Table matching/evaluation and preprocessing interfaces |
| libreoffice | `1acf2756db642e214921f35b7ab2c69980c195bc` | Graphics-state clipping and rendering mode |
| docjev | `c7abe276a970605feb9cb8b27513365b6c10726e` | Page completeness and real-document corpus design |

Reference source was inspected locally. No reference checkout was modified and no specialist models were installed or run. The parser was built with Zig 0.16.0. This review adds a research harness and this report; it does not change parser behavior.

## Fresh evidence

[The probe harness](/Users/thomasmain/projects/pdf-parser/benchmark/eval/reference_review_probes.py) creates seven small PDF reductions and reads four existing Docling fixtures in place. Two fixtures also run with OCR enabled, for thirteen cases total. All native/adaptive commands exited successfully. Success did not imply complete text.

| Case | Observed result | Interpretation |
| --- | --- | --- |
| Two lines inside one `/MCID 0` group | Native: `FIRST\nSECOND`; adaptive spans: only `FIRST`, duplicate count 1 | Confirmed adaptive data loss |
| Same lines without marked-content ID | Both lines survive | Control isolates the reconciliation problem |
| 45-degree positioned `AB CD` | Native: `AB\nCD`; adaptive: two spans `AB`, `CD` | Visual line/word relationship is lost |
| Horizontal version of the same positions | `AB C D` | Extra intra-word space; orientation is not the only boundary issue |
| Ordinary Helvetica with `3 Tr` | Invisible text emitted like ordinary native text; `hidden_ocr = 0` | Visibility is not captured by the font-name heuristic |
| Text wholly outside a rectangular clip | `OUTSIDE-CLIP` emitted like ordinary native text | No public distinction between readable source text and painted text |
| Docling mixed native/path-drawn glyph fixture, OCR enabled | Only `Native`, `Boxed`; no OCR route for the outlined glyphs | Routing lacks a vector-content signal |
| Native text above a vector rule | Native text retained | Useful control against indiscriminate vector-triggered OCR |
| Unique title above body text | Title retained in adaptive public spans | Does not support a blanket claim that public extraction drops page titles |

[Raw evidence](/Users/thomasmain/projects/pdf-parser/benchmark/eval/outputs/reference-review-2026-10-09/probes.json) records input hashes, commands, stderr, text, spans, routes, and duplicate counts. These are focused reductions, not a representative accuracy benchmark. Reference expectations are grounded in local fixture definitions/tests; the reference pipelines themselves were not run.

## 1. Stop treating MCID equality as duplicate identity

**Priority: immediate; relatively small implementation.**

[`findDuplicate`](/Users/thomasmain/projects/pdf-parser/src/reconcile.zig:745) returns a match whenever two spans on the same page have equal MCIDs, before comparing text or geometry. `mergeDuplicate` then frees one span. A marked-content group can contain several distinct lines. Our reduction demonstrates loss of the second line even though native extraction recovered it.

Docling Parse's [cell deduplication](</Volumes/External SSD/referencerepos/docling-parse/src/parse/page_item_sanitators/cells.h:87>) requires text, font, and corresponding quad geometry. The transferable principle is to prove duplication from equivalent content and placement; a structural grouping ID is insufficient.

Remove the unconditional MCID shortcut and retain the existing text/overlap checks as the initial fix. Longer term, distinguish page/content-stream or Form XObject scope and extraction segment identity from semantic group identity. Preserve provenance from equivalent native/OCR candidates without collapsing legitimate siblings.

Acceptance: both lines survive; repeated equivalent spans still deduplicate; identical text at different positions survives; reused MCIDs across Form XObjects do not collide. Add a derived or real tagged-document fixture after the reduction. No public schema change is needed for the narrow fix.

## 2. Carry text visibility through the native/adaptive boundary

**Priority: high; medium scope, staged implementation.**

[`Tr` is ignored by the interpreter](/Users/thomasmain/projects/pdf-parser/src/interpreter.zig:249), and the main extraction path does not retain rendering-mode/clip visibility on text spans. [`hidden_ocr`](/Users/thomasmain/projects/pdf-parser/src/complexity.zig:214) is inferred from font names. Invisible text in ordinary Helvetica therefore looks like visible native text to routing.

Docling [separates visible and invisible PDF cells](</Volumes/External SSD/referencerepos/docling/docling/models/base_ocr_model.py:121>) before OCR merging. Docling Parse [tracks clipped bounds and visibility](</Volumes/External SSD/referencerepos/docling-parse/src/parse/pdf_decoders/page.h:319>). LibreOffice independently [transforms and intersects clip paths](</Volumes/External SSD/referencerepos/libreoffice/sdext/source/pdfimport/tree/pdfiprocessor.cxx:515>).

Start with rendering modes and graphics-state save/restore, then conservative clipping and opacity evidence. Use explicit visible, nonpainting, clipped-out, and uncertain classifications internally. Retain raw embedded text: invisible text can be useful OCR or accessibility content. Make visible-reading selection and raw-source retention separate policies with recorded reasons.

Do not equate every invisible span with OCR, or pretend bbox clipping proves exact visibility for arbitrary paths. Avoid Docling's blanket overlap suppression where it could discard adjacent legitimate text. Compare candidate text and geometry before suppressing embedded or fresh OCR.

Acceptance: ordinary-font invisible text is distinguishable; visible text never loses priority solely because of font names; clipping respects transforms and `q/Q`; partially clipped text retains uncertainty; Type 3 text and text clipping modes have explicit controls. Public visibility/provenance fields require the documented schema/version update; current adaptive schema is 0.13.0.

## 3. Route unexplained vector glyphs to OCR

**Priority: high; depends partly on visibility evidence.**

[`PageInput`](/Users/thomasmain/projects/pdf-parser/src/complexity.zig:20) has native spans, images, and structure evidence, but no general vector-shape regions. Ruling-line extraction is useful for tables; it does not establish coverage of outlined text. On Docling's local outlined-glyph fixture, enabling OCR still leaves the path-drawn letters absent.

Docling's [PDF-aware OCR rectangles](</Volumes/External SSD/referencerepos/docling/docling/models/base_ocr_model.py:372>) consider visible text, bitmaps, and connected shapes together. They exclude thin rules and shapes explained by native text, and judge shape coverage within the candidate region. This avoids treating a tiny caption as an explanation for all chart labels.

Expose bounded vector summaries from the kernel: geometry, paint kind, connected-component bounds, clipping, and simple rule/highlight classification. Let the adaptive layer identify unexplained visual regions and request regional OCR through the existing external adapter. Keep raw path storage optional and bounded.

Acceptance: outlined text beside native text and inside charts gets a recorded OCR request; rules, native text highlights, and ordinary filled boxes do not force OCR. Include merged fills, edge-touching glyphs, and dense decorative drawings. The route must be testable with a deterministic fake OCR adapter before measuring a real OCR engine's accuracy.

## 4. Use one placement-aware line/word boundary model

**Priority: high; medium scope, higher regression risk.**

The parser already projects glyph positions into local writing axes. However, [`sameOrientation`](/Users/thomasmain/projects/pdf-parser/src/native_layout.zig:419) uses an absolute dot product, accepting opposite directions, while [spacing uses a fixed `0.105 * em` threshold](/Users/thomasmain/projects/pdf-parser/src/native_layout.zig:644). Other layout flatteners have separate spacing rules. Our rotated and horizontal reductions show inconsistent boundaries.

Docling Parse's [line continuation](</Volumes/External SSD/referencerepos/docling-parse/src/parse/page_item_sanitators/cells.h:642>) uses signed writing-axis agreement, facing-edge overlap, and bounded cursor jumps scaled by placement advances. Its [word-gap inference](</Volumes/External SSD/referencerepos/docling-parse/src/parse/page_item_sanitators/cells.h:728>) uses line-local normalized gaps, preserving explicit whitespace and limiting inferred thresholds. The [rotated contraction tests](</Volumes/External SSD/referencerepos/docling-parse/tests/test_unit_rotated_cell_contraction.py:14>) explicitly expect words `AB`, `CD` and line `AB CD`.

Reuse the existing glyph boundary/provenance records as the authoritative decision. Partition writing direction first; distinguish line membership from word separation; infer local gaps only when enough evidence exists. Carry those boundaries through span flattening instead of introducing another downstream global threshold.

Acceptance: 45/90/180-degree, vertical, RTL, superscript/subscript, tiny-font, explicit-space, and malformed-width controls. Preserve existing column/gutter safeguards. Evaluate on a new real/derived set before changing defaults; do not tune to one four-letter reduction.

## 5. Add separator and relationship evidence to the hierarchy

**Priority: medium; a new gated experiment.**

The parser already has hierarchy-native reading-order diagnostics. Fresh runs resolve all **96 anchors across 12 real fixtures**. Mean diagnostic precedence F1 is **0.981482 development / 0.943020 holdout**, compared with legacy **0.787322 / 0.791060**. These results do not authorize promotion: the [frozen audit](/Users/thomasmain/projects/pdf-parser/benchmark/eval/reading_order_real/representation-audit.json) records failed required-edge, ambiguity-preservation, and valid-projection gates. The fresh holdout again has only **5/6 valid projections**. Preserve the frozen stop rule and use new development/holdout documents for further experiments.

Docling [constructs filtered page separators](</Volumes/External SSD/referencerepos/docling/docling/models/postprocessing/reading_order_rb.py:303>) from thin filled/stroked shapes, rejects rules inside graphics or crossing content, and requires content on both sides. Its [ordering stage](</Volumes/External SSD/referencerepos/docling/docling/models/postprocessing/reading_order_rb.py:414>) preserves header/footer elements. Its [container assembly](</Volumes/External SSD/referencerepos/docling/docling/models/stages/reading_order/readingorder_model.py:93>) maintains parent/child ownership and provenance.

Feed validated separator evidence into the existing hierarchy rather than replacing it with a flat sort. Add caption/footnote ownership and spanning-region constraints. Preserve furniture as classified nodes, with explicit exclusion policies and cross-page recurrence evidence. The old flat-block audit shows header-removal representation failures, but the fresh public-title control passes; these are different surfaces.

Acceptance: required edges, forbidden paths, ambiguity preservation, valid projections, source coverage, determinism, and ReleaseFast overhead. Keep diagnostics separate from applying a new order.

## 6. Separate table topology prediction from text extraction

**Priority: medium; optional specialist capability.**

The native table grid already supports rich cell spans, roles, continuations, and provenance. Build on it. Table protocol records exist, but formula execution is the implemented specialist path today; a protocol family alone does not establish a working table adapter.

Docling's [table model](</Volumes/External SSD/referencerepos/docling/docling/models/stages/table_structure/table_structure_model_v2.py:120>) predicts topology, then [matches existing PDF/OCR text cells](</Volumes/External SSD/referencerepos/docling/docling/models/stages/table_structure/table_structure_model_v2.py:196>) through a spatial index. PaddleOCR's [table matcher](</Volumes/External SSD/referencerepos/PaddleOCR/ppstructure/table/table_master_match.py:321>) provides containment, overlap, and unmatched-cell fallbacks. Its [TEDS implementation](</Volumes/External SSD/referencerepos/PaddleOCR/ppstructure/table/table_metric/table_metric.py:109>) evaluates structure and optionally content.

Implement an opt-in specialist that returns topology/cell geometry and attaches existing text with source IDs. Validate bounds, spans, overlaps, assignment uniqueness, and reading order. Abstain on ambiguous assignments rather than blindly copying nearest-cell fallback. Docling's overlap threshold is also not a complete ownership policy: one text cell can match multiple predicted cells.

Compute actual topology metrics in the host evaluation harness. [`eval_runner` currently passes through `options.teds`](/Users/thomasmain/projects/pdf-parser/src/eval_runner.zig:413); the presence of a TEDS field does not mean it is measured. Keep existing exact numeric, row/column/span, and source-coverage metrics alongside TEDS or GriTS.

## 7. Make completeness and evaluation lanes explicit

**Priority: high for quality infrastructure; independent of model work.**

Docjev's [page validator](</Volumes/External SSD/referencerepos/docjev/src/jev_docs/documents.py:16>) checks exact page sequence/count and verifies visually blank pages before accepting empty extraction. Docling computes [page parse quality from the weakest tenth of cells](</Volumes/External SSD/referencerepos/docling/docling/models/stages/page_preprocessing/page_preprocessing_model.py:118>) and [document parse quality from the weakest tenth of pages](</Volumes/External SSD/referencerepos/docling/docling/pipeline/standard_pdf_pipeline.py:1122>). These mechanisms expose local failures that average confidence can hide.

Add coverage accounting across raw spans, reconciliation, selection, and public emission. Classify each page as completed, verified blank, needs review, or failed, and distinguish text completeness from graphics-only content. Retain reasons and unresolved routes. Extend lifecycle receipts compatibly, with an opt-in strict mode and the required schema update. A page count alone would not catch the MCID loss; post-reconciliation source accounting is essential.

Also make benchmark lanes match the boundary they claim to measure. The CLI [can supply verified `pdftotext` readable fallback](/Users/thomasmain/projects/pdf-parser/src/main.zig:1167), whereas [adaptive evaluation calls the library directly](/Users/thomasmain/projects/pdf-parser/src/eval_runner.zig:482). Report native, augmented CLI, and specialist lanes separately, including executable/config identities. The fresh graph score run contains poor text metrics on some fixtures (first fixture token F1 0.125090); graph success therefore is not evidence of general text quality. Those text results require a separate lane/ground-truth investigation.

Broaden regional render-oracle controls: expected visible and clipped regions need meaningful coverage floors. Whole-page averages can hide small missing labels. Docling Parse's clipping tests illustrate local-region checks.

Docjev's [real-small corpus card](</Volumes/External SSD/referencerepos/docjev/datasets/real-small/v1/DATASET_CARD.md:3>) describes 40 authentic PDFs/116 source pages with explicit issuer/template dependence. It is useful for sourcing additional local inputs, not extraction ground truth. Add extraction annotations and split by template/issuer where generalization is claimed; do not treat its classification labels as text/table truth. Keep raw PDFs in ignored caches and respect provenance/redistribution limits.

## 8. Improve semantic hierarchy; measure preprocessing and concurrency later

**Priority: medium for hierarchy; lower until measured for the others.**

Docling's [heading inference](</Volumes/External SSD/referencerepos/docling/docling/models/stages/heading_hierarchy/heading_hierarchy_model.py:4>) prefers matched bookmarks, then numbering, then style. The parser already parses outlines and font-based headings. Connect those signals into block/chunk section ancestry, preserving source evidence and abstaining on ambiguous matches. Avoid treating dates as numbered headings. Richer public chunk/block fields need a schema update.

PaddleOCR exposes [document orientation, unwarping, text-line orientation, and ruled/borderless table options](</Volumes/External SSD/referencerepos/PaddleOCR/paddleocr/_pipelines/pp_structurev3.py:32>). Much of PP-StructureV3 delegates to PaddleX, so this local wrapper does not prove the underlying algorithms' behavior. Consider bounded preprocessing retries through specialist contracts only after scan failures are measured. Preserve reverse coordinate transforms; nonlinear unwarping needs a mapping, not merely a rotation flag.

Docling's [bounded threaded queue](</Volumes/External SSD/referencerepos/docling/docling/pipeline/standard_pdf_pipeline.py:163>) is a useful eventual host-stage pattern: backpressure, close semantics, and per-run failure handling. The parser already releases page results in streaming mode. Instrument page/object-cache lifetimes and measure ReleaseFast lanes before adding concurrency. Keep deterministic output ordering and allocator ownership clear. No performance claim follows from this Debug review.

## Recommended delivery sequence

1. Fix MCID reconciliation with focused regression controls. Add post-reconciliation source coverage assertions to the research/eval boundary.
2. Implement visibility metadata and vector summaries internally; validate routing without a model, then evaluate regional OCR. Version public fields deliberately.
3. Consolidate line/word boundaries behind diagnostics and new real/derived controls before changing defaults.
4. Start a fresh separator/relationship experiment and an independent optional table-topology adapter. Preserve the existing reading-order holdout stop rule.
5. Improve semantic chunks and consider preprocessing/concurrency only with measured failure or performance evidence.

## Validation and reproduction

Fresh checks: **build 11/11 steps passed; tests 60/60 steps and 2,886/2,886 tests passed**. Those tests establish the current suite's baseline, not absence of the newly reproduced defects. No parser code changed.

```sh
zig build --cache-dir .zig-cache --global-cache-dir .zig-cache/global --summary all
zig build test --cache-dir .zig-cache --global-cache-dir .zig-cache/global --summary all
python3 benchmark/eval/reference_review_probes.py
zig-out/bin/pdf-parser-eval --adaptive --disable-ocr --reading-order-mode diagnostic --reading-graph-audit --manifest benchmark/eval/reading_order_real/manifest.tsv --output benchmark/eval/outputs/reference-review-2026-10-09/reading-order-audit.jsonl
zig-out/bin/pdf-parser-eval --adaptive --disable-ocr --reading-order-mode diagnostic --manifest benchmark/eval/reading_order_real/manifest.tsv --output benchmark/eval/outputs/reference-review-2026-10-09/reading-order-scores.jsonl
```

Generated reductions and JSONL evidence remain under ignored eval outputs. The harness reads local reference PDFs in place and does not copy them into the tracked corpus. Evidence is narrow correctness/graph evidence; no head-to-head model benchmark, broad ranking, or speedup has been established.
