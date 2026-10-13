# Table region development controls

Eight small, independent drawing specifications exercise region assembly and
persistent columns. They are development controls, with no holdout or
continuation qualification claim. The corpus and literal truth were frozen
before their first parser assessment. No authentic heldout content was used to
choose their labels, amounts, geometry, or expected matrices.

The controls cover stacked different grids, partial subtotal rules, centered
headers above aligned bodies, complete statements across subtotal bands,
diagram/prose negatives, mixed ruled and borderless tables, prose overlapping
the horizontal table extent, and separate tables with identical column
alignment. The last case checks the public region boundary; it makes no claim
about the internal layout block identity.

```sh
python3 benchmark/eval/table_regions/generate.py --check
python3 -m unittest discover -s benchmark/eval/table_regions -p 'test_*.py'
python3 benchmark/eval/table_regions/verify.py \
  --cli zig-out/bin/pdf-parser \
  --output benchmark/eval/outputs/table-regions-unique-run
```

The verifier drives both public JSONL formats with `--no-ocr`. It reuses the
bounded subprocess runner from the real-document harness: timeout, sampled
output budget, and finalization of only the process group it created. Each run
requires a new evidence directory and retains commands, raw output, stderr,
execution receipts, binary/dependency hashes, frozen corpus identity, and
individual scoring results. Budget enforcement is sampled and may overshoot;
it is not a filesystem quota.

Acceptance requires exact table count, regular cell occupancy, column extent,
literal cell strings, exclusive source span ownership, matching source text,
live owning block references, source/input identity, and the correct public
lifecycle. Blank, zero, dash, and parenthesized amounts remain distinct.
The token multiset of every emitted reconciled span must equal all drawn cell
and prose tokens, including text outside the selected table/prose regions.
Table source references must equal the union of their cell sources. Reconciled
span, block, and cell references must agree reciprocally on live ownership and
provenance. Blocks expose `span_start`, `span_count`, and `provenance.span_ids`;
their declared interval must match both emitted span order and reciprocal span
ownership. Blocks do not expose the table/cell `source_span_ids` field.
Table `provenance.block_ids` retains the documented legacy layout
block interval; it is separate from the reconciled owner namespace.
Retained prose must be present in its independently drawn region and remain
outside both cell ownership and table regions. Every span, block, table, row,
and cell assessed for geometry has a finite object bbox in raw PDF points.

Expected regions are drawing envelopes, not exact native text bounds. Actual
tables must fit their envelope within six points, overlap at least 45 percent
of its area, and have at least 85 percent of their own area inside it. This
allows padding and section gaps while rejecting tiny fragments and unrelated
regions. Rows, cells, and source spans use a two-point containment tolerance.
Nonblank regular cells and their source spans must fit their own physical row
within two points. Separate table regions may not overlap. Drawing truth and
region thresholds were fixed before the first parser observation; no
result-driven threshold or truth changes are permitted. Corrections to source
inventory, reference reciprocity, row containment, and the legacy layout
namespace are harness fixes. Preserve earlier reports and identify any replay
under the corrected verifier separately.

`generate.py` refuses to overwrite different frozen bytes. Any future drawing
change belongs in a new fixture/version with its own freeze and baseline.
Passing this pack demonstrates these drawing specifications, not arbitrary
real-document table reconstruction.
