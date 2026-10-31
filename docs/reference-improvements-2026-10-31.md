# Parser improvements from local reference mechanisms

Reviewed 2026-10-31 at parser revision `5e2c718340c6df57a00d9e0bd1e3655d7d001eb8`, with a clean starting worktree and installed Zig `0.17.0` matching `.zig-version`. This is a research result; parser behavior was not changed.

Follow-up: the authorized [implementation and local verification](parser-improvements-2026-10-31.md) implements the five decisions below. This research report retains the evidence and limitations of the earlier source snapshot.

The highest-value first change is **one table-continuation policy shared by batch and streaming**. A fresh controlled exercise reproduces different logical table identities for the same PDF. After that, address signed writing direction, section ancestry, precise quote geometry, and decoder-budget propagation.

## Ranked decisions

| Priority | Improvement | Evidence | Cheapest next target check |
| --- | --- | --- | --- |
| 1 | Share table continuation semantics across output lanes | Reproduced in six CLI runs, with positive and negative controls | Turn the three probe cases into a permanent cross-format regression; add identical-but-unrelated tables, missing headers, interleaving and page gaps |
| 2 | Partition line assembly by signed writing direction | Current source plus a three-case predicate model; no actual PDF failure reproduced | Opposite-axis glyphs on coincident baselines, alongside same-axis, quarter-turn, mirrored and bidi controls |
| 3 | Attach section ancestry to blocks and chunks | Current target/source comparison with Docling and its test definitions | Bookmark/numbering disagreement, wrong-page duplicate titles, ambiguous same-page headings, dates and numbered-list controls |
| 4 | Add optional subspan geometry for quote highlights | Current contract explicitly provides span-bbox precision; MuPDF retains character quads | Substring, wrapped quote, rotated text, ligature and ActualText geometry assertions |
| 5 | Carry decoder budgets and refusal reasons across all filters/callers | Source-supported scope/error-handling gaps; no whole-process exhaustion test | Tiny configurable caps across Flate/LZW/RunLength/filter chains, plus failed decode and cumulative document-cache controls |

## 1. Make table identity independent of serialization format

[Batch continuation](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/src/adaptive.zig#L1416) accepts at least 75% matching comparable header cells. [Streaming continuation](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/src/stream.zig#L368) requires exact lowercased header hashes. Both also accept a later page without requiring adjacency or explaining a gap.

The new probe report (local ignored evidence: `benchmark/eval/outputs/repo-learning-2026-10-31/table-probe/report.json`) records:

| Four-column headers across two pages | artifact-jsonl | stream-jsonl |
| --- | --- | --- |
| All labels match | Linked | Linked |
| Three match; one changes | Linked | Separate |
| All labels unrelated | Separate | Separate |

All six CLI runs exited zero and emitted two page-local tables. This establishes an inconsistency, not which interpretation of the partial header is correct. Share a bounded signature and decision policy, preserve page-local parts, and abstain when continuation ownership is ambiguous. Streaming need not gain batch-only future knowledge or forward links.

The installed binary SHA256 is `a87698a1537e9395ff19263801974cd9f2f638578db3d5f99052047fc630dd34`. The probe checked it against the retained final-verification receipt, checked that receipt's HEAD against the current revision, and rehashed all its recorded source entries. All matched. It did not rebuild the binary.

Marker's [candidate scoring](https://github.com/datalab-to/marker/blob/71dd5fd7e51ab24f8624b6ba2fcb6014b4e40ed4/marker/processors/table_recon.py#L187) is a conditional follow-on: compare bounded grid hypotheses before selecting one. Its scores do not establish calibrated confidence. Keep the parser's exact source ownership, geometry and raw numeric strings authoritative; aligned narrative lists are a negative control. pdfplumber's [literal invoice assertions](https://github.com/jsvine/pdfplumber/blob/4c64b92d5caccd71c645e98e0fabb0c4dba7ff45/tests/test_table.py#L54) are a useful independent test-design reference.

The newer [statement qualification](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/docs/statement-assembly-qualification.md#L28) supersedes the older finding that selected real development statements were fragmented. The [real-table pack](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/benchmark/eval/table_topology_real/README.md#L53) still covers selected truth rather than complete-table accuracy and has only one positive continuation template. Add fresh template-disjoint positive continuations and full row/cell inventories; preserve previously observed holdouts.

## 2. Keep opposite writing axes out of one line

[sameOrientation](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/src/native_layout.zig#L444) takes the absolute dot product, so `(1,0)` and `(-1,0)` are compatible. Line membership consumes that predicate, while inline sorting projects each glyph using its own axis. This is a concrete source-level mismatch; actual PDF corruption has not been reproduced.

Docling Parse's [line continuation](https://github.com/docling-project/docling-parse/blob/e90fee2ef63c8424c385db2cffc5fca6d5052e8c/src/parse/page_item_sanitators/cells.h#L642) requires a signed dot product, facing-edge evidence and a bounded cursor jump. Transfer the signed-direction invariant rather than copying its numeric threshold. A quarter-turn is different from an opposite axis, and geometric direction is different from Unicode bidi order.

The local `direction_model.py` checks same, perpendicular and opposite axes. It is explicitly a model of the predicates, not a Zig or reference-pipeline test. Existing target 45-degree and vertical tests do not settle the opposite-axis case. Freeze a minimal fixture at a coincident baseline before changing defaults, then check mirrored, 180-degree, vertical, superscript and explicit-space cases.

## 3. Use existing outlines to annotate section ancestry

The target already parses bookmark title/page/level in `src/outline.zig`, but the inspected adaptive/reconcile/chunk seams do not consume them. Reconciled blocks/chunks have no section ancestry, and [heading Markdown](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/src/reconcile.zig#L280) uses one fixed level.

Docling's [heading pass](https://github.com/docling-project/docling/blob/764b5d4dc22b03ea87afd4c2207f510300b27a5b/docling/models/stages/heading_hierarchy/heading_hierarchy_model.py#L619) preserves signal precedence: matched bookmark, then numbering, then style. Apply a deterministic annotation pass after block text/identity/order stabilize. Link section owners to existing block/chunk IDs; do not reorder text to add hierarchy. Public additions require the schema/version/docs/tests policy.

Reject ambiguous repeated titles and wrong-page matches. Current target outlines lack destination Y, so two identical headings on one page may not have a unique owner. Do not copy a greedy tie-break as an evidence guarantee. Numbered dates, financial values and body lists must remain negative controls. Chunks spanning sections need explicit multiple ownership or splitting while retaining exact source maps.

Reading-order promotion remains separate. The old real-document audit failed required-edge, ambiguity-preservation and valid-projection gates. The newer synthetic controls do not revoke those failures. Keep default legacy order until fresh preregistered real-document gates support a change.

## 4. Extend geometry precision without inventing character evidence

The [current text contract](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/docs/output-schema.md#L491) already has exact text hashes, half-open UTF-8 byte maps, chunk-to-block-to-span provenance, null synthetic separators and page transforms. Those are delivered features, not new recommendations.

The missing public precision is a selected substring's actual glyph geometry. [MuPDF characters](https://github.com/ArtifexSoftware/mupdf/blob/63c8e2652fcb9207b5bba9ecb4fb366b160ff85f/include/mupdf/fitz/structured-text.h#L480) retain quads; its [highlight merger](https://github.com/ArtifexSoftware/mupdf/blob/63c8e2652fcb9207b5bba9ecb4fb366b160ff85f/source/fitz/stext-search.c#L1649) combines only suitably adjacent regions. Consider optional source-range geometry with declared precision, retaining coarse span geometry when that is all the evidence supports.

ActualText can replace several glyphs with arbitrary semantic text; proportional bbox subdivision would invent evidence. Ligatures, OCR words and synthetic whitespace likewise need explicit grouping or unknown precision. Retain multiple disjoint quads for wrapped/rotated quotes. This proposal independently implements a mechanism; it does not select MuPDF as a dependency.

## 5. Extend resource controls at their actual allocation boundaries

The parser already bounds Flate growth during allocation and caps LZW output. Streaming already limits output bytes and adaptive page allocation. Its [documented exclusions](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/docs/output-schema.md#L640) include document caches/mappings, allocator overhead and subprocess RSS.

[RunLength decoding](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/src/decompress.zig#L657) appends without the common decoded-output cap, and [page-content decoding](https://github.com/Tom-R-Main/pdf-parser/blob/5e2c718340c6df57a00d9e0bd1e3655d7d001eb8/src/pagetree.zig#L633) catches every decompression error and returns raw stream bytes. A budget refusal therefore lacks a distinct outcome at that boundary. Keep malformed-input recovery separate from resource refusal, with strict failure or explicit unresolved coverage for the latter.

PDF Oxide's [bounded Flate reader](https://github.com/yfedoseev/pdf_oxide/blob/08accb2e0be8252309083a33fafc74015269594c/src/decoders/flate.rs#L145) and small-cap tests are useful references. Its separate post-filter size/ratio check happens after a decoder has allocated output: that check alone cannot establish a peak-allocation bound. Keep the parser's existing bounded-growth property and extend policy through filter chains, predictors and document-owned caches. A per-stream cap does not prove bounded aggregate memory.

## Evidence, durable learning and limits

Source snapshots and pattern cards are retained in the maintainer's private reference library. They include hashes, HEADs, counterexamples, target checks and validation levels. Generated CLI evidence stays under ignored `benchmark/eval/outputs/repo-learning-2026-10-31/`; it is not bundled with this repository. The public source links above are pinned to the revisions inspected.

The five new retrieval IDs are `serialization-independent-table-identity-v1`, `signed-writing-axis-line-membership-v1`, `section-ancestry-signal-precedence-v1`, `highlight-only-supported-glyph-geometry-v1`, and `decoder-budgets-survive-recovery-v1`. Alternate-wording queries were compared with the existing owners before adding them. Shared vocabulary with search pagination, general partial completion, or generic citation rules did not cover these narrower applicability boundaries.

A fresh-context retrieval check found the table-identity and quote-geometry cards at rank one from differently worded problems, with all their linked evidence fresh. It correctly rejected requiring future streaming links and subdividing ActualText bounds into invented character rectangles. This validates retrieval and rejection behavior, not parser correctness or accuracy gains.

Local reference HEADs: Docling `764b5d4dc22b03ea87afd4c2207f510300b27a5b`; Docling Parse `e90fee2ef63c8424c385db2cffc5fca6d5052e8c`; MuPDF `63c8e2652fcb9207b5bba9ecb4fb366b160ff85f`; pdfplumber `4c64b92d5caccd71c645e98e0fabb0c4dba7ff45`; PDF Oxide `08accb2e0be8252309083a33fafc74015269594c`; Marker `71dd5fd7e51ab24f8624b6ba2fcb6014b4e40ed4`.

Executed target validation is limited to the six table CLI cases and the direction predicate model. Reference tests were inspected, not executed. No full suite, accuracy scorecard, performance benchmark, specialist model, network fetch/install, production code change, commit or deployment occurred. Future implementation should use the Zig domain skill and normal target verification recipe.

Reproduce the fresh checks:

```sh
python3 benchmark/eval/outputs/repo-learning-2026-10-31/table-probe/probe.py
python3 benchmark/eval/outputs/repo-learning-2026-10-31/direction_model.py
```
