# Section and wrapped-row assembly

Locally checked on 2026-10-13. Schema `0.19.4` is a local continuation of the
table-region work. Public fields,
types, font metadata and raw PDF coordinate meanings remain unchanged.

Native statement bands use repeated amount-column alignment to corroborate
section labels and attach wrapped label fragments in either direction.
Section labels occupy ordinary stub cells with blank amount cells. Label
attachments extend the row's bounds and retain exact source membership.
Repeated field headers separate statements; ambiguous chains, narrative lists,
captions and unsupported notes retain their native text. Refused source leaves
cannot be reclaimed by the older heuristic table path.

The actual adaptive span producer carries a private font-scale estimate from
the text and graphics transforms. Only the preferred table view uses it.
Three equivalent 12-point encodings, including an inverse-scaled declared
font size of 120, pass through the document API without changing public font
metadata or leaking the private field into JSON. Padded currency/dash fields
retain their literal text and source spans.

Eight development drawings and their exact truth were frozen before parser
assessment. The archived baseline passed 8 of 16 public CLI runs; the current
implementation passes all 16. File and memory entry points through Python/C
ABI pass all 32 runs. Both public JSONL formats are covered. The scorer checks
exact cells, complete source tokens, exclusive reciprocal ownership, finite
physical bounds, retained prose and lifecycle. Independently frozen row
envelopes reject a displaced cell even when emitted bounds expand around it.

The existing table-region controls pass 16 runs, topology controls pass 16,
and emitted-order controls pass 28. The allowed real development report now
passes both formats: its three selected statements each form one region,
selected literal rows remain exact, and separate statements have separate
logical identities. This gate checks frozen regions, selected rows and
relations; it does not establish full-table accuracy. Previously observed real
holdouts were not inspected or used to tune this implementation.

JavaScript checks pass 339 tests and Python verification harnesses pass 147.
The adaptive corpus evaluation completed with 36 records and no stderr.
The public ABI runs above use the existing CFFI environment; the optional
pytest suite remains unavailable, and no tooling was installed.
The final compiler batch completed all 82 steps, including full Zig tests,
native/shared/WASM builds and the native corpus scorecard. Its summary reports
4,284 passes and nine skips; cached focused test steps are additional.
Independent readbacks found no remaining actionable issues after remediation.
The reviewers used the inherited session model in separate contexts; its exact
model identifier was unavailable. These checks establish local correctness,
with no performance, remote CI or merge claim.

Regression tests cover prefixes, suffixes, nested sections, digit-bearing
labels, referenced notes, formula/list/prose negatives, transformed fonts,
allocation rollback, and fallback source refusal. A short final gap causes a
section chain to abstain as a whole rather than partially merge into a detail
row. Section chains contain at most four stubs; currency/dash recognition
scans at most 64 spans and 256 bytes. Existing table construction limits still
apply, with native fallback on ambiguous or exhausted evidence.

Evidence is retained under ignored
`benchmark/eval/outputs/statement-rows-2026-10-13/` and
`benchmark/eval/outputs/statement-regions-2026-10-13/`: failed and passing
assessments, raw public outputs, artifact/source hashes, compiler logs and
receipts, independent readbacks, and the exact-cache closeout receipt.
Compiler work uses one dedicated task cache with a sampled 1.5 GiB allocation
limit and 3 GiB free-space floor. These controls are not a filesystem quota or
a whole-process memory limit. Evidence, deliverables and cached tooling remain
outside the reclaimed task subtree.
The final compiler batch observed a 1.16 GiB peak with no sampled overshoot.

To replay the drawings:

```sh
python3 benchmark/eval/statement_regions/generate.py --check
python3 benchmark/eval/statement_regions/freeze_geometry.py --check
python3 -m unittest discover -s benchmark/eval/statement_regions -p 'test_*.py'
python3 benchmark/eval/statement_regions/verify.py \
  --cli zig-out/bin/pdf-parser \
  --output benchmark/eval/outputs/statement-regions-unique-run
```

Next: acquire fresh issuer/template-disjoint merged-cell and continuation
holdouts, freeze their truth before the first assessment, and report them
separately from these development reductions.
