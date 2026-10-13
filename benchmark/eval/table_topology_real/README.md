# Real-document table regions and continuation

This pack checks selected rows, literal merged header cells, and continuation
links in three complete government publications. It complements the frozen
synthetic topology pack; it does not measure complete-table topology accuracy.

The development source is an NCUA financial report. Treasury cash/debt tables
and Census construction tables are holdouts. Issuers and template families are
disjoint across the split. Source cards bind complete original PDFs by SHA256,
physical page count, source URL, and the reference checkout commit. Rights
metadata is retained from those cards; no agency endorses this evaluation.

Independent Poppler text, word geometry, and source renders established truth
before parser assessment. Rendered rules establish Census header spans of two
and three columns, with a two-row stub. The Treasury debt-limit table includes
an integrated caption, two vertically merged headers, and three opening-balance
periods. Approximate raw PDF regions select tables; they do not qualify exact
cell-edge geometry. `freeze.json` binds source cards, selected truth, selectors,
and the blind evidence inventory.

Both public JSONL formats are assessed independently. Missing or ambiguous
tables fail. Negative continuation checks require both tables to exist;
positive links must be reciprocal with a shared logical identity and consecutive
part indices. Row checks preserve currency markers, zeros, dashes, parentheses,
and `NA`, with whitespace normalization only. Treasury prefix checks select the
deposit/issues panel without combining its entity with an adjacent withdrawal
or redemption panel. Header checks require literal placement and spans. Context
notes describe source units and measurement bases; they are not assertions of a
public unit field.

Prepare existing local originals without downloading or overwriting mismatches:

```sh
python3 benchmark/eval/table_topology_real/prepare.py \
  --source-root /path/to/originals
python3 -m unittest discover -s benchmark/eval/table_topology_real -p 'test_*.py'
```

The default prepared input directory is ignored
`benchmark/eval/raw_cache/table_topology_real`. Complete source files remain
outside Git. Assess development first, then the frozen holdouts:

```sh
python3 benchmark/eval/table_topology_real/verify.py \
  --cli zig-out/bin/pdf-parser --split dev \
  --output benchmark/eval/outputs/real-table-dev
python3 benchmark/eval/table_topology_real/verify.py \
  --cli zig-out/bin/pdf-parser --split holdout \
  --output benchmark/eval/outputs/real-table-holdout
```

Output directories must be new. Each run preserves commands, raw output,
stderr, failures, source/binary/verifier hashes, and a report. A failed
qualification exits nonzero; a failed baseline remains useful evidence.
CI tests the scorer and frozen metadata without fetching the source PDFs.

Only one explicit positive-continuation source/template is represented. The
Treasury Table IIIA/IIIB pair and the Census annualized/unadjusted pair are
negative controls despite repeated headers or amounts. Distinct NCUA statements
are negatives too. Do not infer cross-template positive-continuation accuracy.

Default local Treasury renders failed because unembedded Helvetica substituted
incorrectly. Blind review used an isolated Fontconfig file and existing Arial
fonts, with its cache under the ignored evidence directory; failed renders were
preserved. NCUA footer rendering is excluded from truth.

Retain observed failures. Do not tune selectors, truth, thresholds, or parser
behavior around these holdouts. Correct objective harness defects with
regressions and preserve the original report. Future parser changes need separate
development evidence and fresh holdouts before broader qualification claims.
