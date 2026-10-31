# Parser 0.20 implementation and local verification

This record describes local implementation and checks on 2026-10-31 over
`5e2c718340c6df57a00d9e0bd1e3655d7d001eb8`, using Zig `0.17.0`. The checks
preceded commit and hosted CI; they establish local behavior. No reference
source was added as a dependency. Later delivery state belongs to the PR and
its checks, not to these earlier local receipts.

## Result

- **Table identity:** one allocation-free bounded policy serves batch and
  streaming. It requires adjacent pages, exact case-insensitive first-header
  cells with matching cell positions/spans and compatible table geometry.
  Partial headers, missing/oversized evidence, page gaps and intervening tables
  abstain. Batch retains reciprocal links; streaming retains backward links.
- **Writing direction:** line assembly requires signed writing-axis agreement,
  including vertical writing. Opposite axes and degenerate/nonfinite placement
  no longer qualify as one orientation. Source text remains available.
- **Sections:** blocks receive conservative bookmark → numbering → style
  annotations, with document-global heading block IDs and cross-page state.
  Ambiguous boundaries clear active ancestry. Chunks list multiple section
  owners without changing text or source maps; Markdown uses supported levels.
- **Quote geometry:** `--include-glyph-geometry` adds source-range glyph quads
  where available. A ligature remains one indivisible glyph; ActualText retains
  grouped bbox precision without an invented quad. Default arrays are empty.
- **Decoder limits:** `--max-decoded-stream-bytes N` caps output growth per
  filter/predictor stage, including raw streams, fonts and lazy object streams.
  Limits reach forms, images, outlines and structure resolution. Fallible
  extraction paths propagate resource refusals through permissive recovery;
  either order of the limit flag and `--permissive` preserves the limit.

Schema `0.20.0` adds section and geometry fields, retaining existing compatibility
fields and exact text views. Both JavaScript readers accept and validate it;
streaming validates cross-page ancestry before returning a complete receipt.
Adapters expose `includeGlyphGeometry` and `maxDecodedStreamBytes`, with matching
TypeScript declarations. The [output contract](output-schema.md) specifies
precision, ownership and budget scopes.

## Observed checks

| Check | Result |
| --- | --- |
| Tracked/new Zig formatting and diff whitespace | Passed |
| `zig build test --summary all -j2` | 62/62 steps; 4,700 passed, 10 skipped |
| `zig build --summary all -j2` | 12/12 steps |
| `zig build shared wasm --summary all -j2` | 9/9 steps |
| Complete JavaScript suite against final executable | 380 passed, no skips |
| Cross-format table controls | All 5 cases passed in both formats |
| Geometry/direction/decoder public harness | All 40 CLI runs met their assertions |
| Section public harness | All 4 CLI cases passed, including batch/stream text-map parity |
| Existing table-region controls | 16/16 verified |
| Existing statement-region controls | 16/16 verified |
| Adaptive corpus with local Tesseract/Poppler | 36 records; command exited zero |
| Born-digital and hard-font capability gates | Passed; 18/18 build steps |
| Reading-order development replay | 14/14 public checks passed; 7 internal diagnostic checks failed |

The seven graph-diagnostic failure lists match the retained 2026-10-12 report
exactly. The latest 2026-10-13 public-only replay did not run that optional
diagnostic lane. No frozen truth, threshold or stop rule was changed; legacy
order remains the default and graph promotion remains unqualified.

Initial experiments and failures are retained alongside final evidence. These
include the original format-dependent table linkage and swallowed decoder
refusals. Allocation-failure checks also exposed a heap-dependent test count:
the ownership probe now forces the allocating shrink path for deterministic
failure injection, and gutter allocation refusal propagates.

## Evidence and limits

The ignored evidence directory is
`benchmark/eval/outputs/repo-learning-2026-10-31/`. It contains final build/test
logs, raw CLI outputs, fixture/binary/harness hashes, the earlier failed runs,
and `verification-final.json` binding the checks to source and artifact hashes.
The maintainer's private repo-learn library retains the initial source
observations and evidence snapshots. This report records target adoption; the
third-party source snapshots are not distributed with the repository.

The three public replay commands are documented in the
[evaluation feature map](../benchmark/eval/README.md). The work used separate
contexts with the inherited session model for implementation and checks; the
exact model identifier was not exposed. This is not evidence from different
model families or an external review.

These results establish the specified local behavior. New real-document
hierarchy, quote-highlight visual accuracy and general table continuation
accuracy have not been qualified. Adjacent unrelated tables can share exact
headers and geometry. Geometry derives from placement/font metrics rather
than painted-pixel outlines. Decoder limits are per stage, not aggregate
document or process memory limits. No performance improvement is claimed.

## Review follow-up: numbering and outline safety

The review reproduced a `u8` overflow on a 256-component dotted heading and a
segmentation fault while traversing a self-referencing outline child. Both are
fixed locally: numeric depth saturates before arithmetic, and outline traversal
tracks visited object references with a separate 64-level recursion bound.
Stopping a cyclic or deep child branch preserves later siblings and page text.
Public fields and schema `0.20.0` remain unchanged.

New unit controls cover depths around 12, 255, 256 and 1,024 with and without
the PART offset, cyclic children and siblings, deep acyclic outlines, and
allocation-failure cleanup. Both original PDFs now complete successfully in
both JSONL formats. The new `benchmark/eval/section_safety.py` adds 12 passing
CLI runs with explicit completion, text retention and timeout assertions; the
four existing section-ancestry CLI cases also pass.

After these fixes, the full Zig gate reports 62/62 steps, 4,924 passed tests
and 10 skips. Native builds pass 12/12 steps; shared/WASM builds pass 9/9.
All 380 JavaScript tests pass with test files run serially. The first parallel
JavaScript run had one existing 500 ms timeout test fail because its child PID
file was absent; the isolated retry and complete serial rerun both pass without
changing that test or its assertions.

Current evidence is under
`benchmark/eval/outputs/repo-learning-2026-10-31/review-fixes/`, including
`verification.json`, the original-input replay results and all build/test logs.
The earlier evidence and failed review reproductions remain preserved.
