# Statement assembly development drawings

Eight independent drawings exercise bounded section and wrapped-row assembly.
Their PDF bytes, exact truth matrices, and geometry tolerances were frozen
before their first parser assessment. No existing real holdout content was
inspected to choose these drawings, and the earlier evaluation packs remain
unchanged.

The positive drawings contain internal section labels with blank amount cells,
two-line labels before or after their numeric baseline, indented detail rows,
subtotal rules, and sparse blank/zero/dash amounts. The boundary drawings retain
intervening prose, distinct same-alignment statements with repeated headers,
detached label-like text, and ordinary page prose with a section heading.
Section labels are regular column-zero cells with blank numeric cells. This
pack makes no merged-cell or continuation qualification claim.

```sh
python3 benchmark/eval/statement_regions/generate.py --check
python3 benchmark/eval/statement_regions/freeze_geometry.py --check
python3 -m unittest discover -s benchmark/eval/statement_regions -p 'test_*.py'
python3 benchmark/eval/statement_regions/verify.py \
  --cli zig-out/bin/pdf-parser \
  --output benchmark/eval/outputs/statement-regions-unique-run
```

The verifier wraps the strict `table_regions` scorer without weakening its
exact table/cell truth, complete span token inventory, exclusive reciprocal
ownership, physical row geometry, legacy table layout namespace, source/input
identity, retained prose, or lifecycle checks. A wrapped cell and every claimed
source span must still fit its declared physical row within two points.
The supplemental `row_geometry.json` freezes independently drawn row envelopes
directly from the original generator coordinates. Its separate geometry freeze
binds the unchanged original freeze. Nonblank cells and their source spans must
also fit their corresponding frozen physical row within two points, even if an
emitted row bbox expands to mask an incorrect association. Native row whitespace
edges need not equal the drawing envelope exactly.
Table envelopes retain the same six-point containment tolerance and fixed
85-percent actual/45-percent expected overlap floors.

Both public JSONL formats run with `--no-ocr` through the existing bounded
subprocess runner. A new evidence directory retains commands, raw output,
stderr, execution details, binary/shared-verifier hashes, freeze identity, and
individual results. Time/output enforcement is sampled, with possible
overshoot. Generation refuses differing frozen bytes; later drawing changes
require a new fixture/version and baseline. Passing these controls qualifies
their drawing specifications, not arbitrary real statements.
