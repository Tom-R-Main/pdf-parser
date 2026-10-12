# Table topology controls

Eight small deterministic PDFs split into four development and four held-out
cases. They cover ruled blank-versus-zero cells, parentheses negatives,
right-to-left content streams with independently positioned cell tokens,
text crossing shared row rules, and graphic-axis no-table controls.
`freeze.json` binds PDF bytes, cell truth, case selection and acceptance before
evaluation. These synthetic reductions do not qualify arbitrary real tables.

The verifier drives both public JSONL formats with OCR disabled. It scores
physical row/column spans independently of flattened cell text, resolves cell
source IDs to exact emitted text on the same page, rejects duplicate owners
and empty-cell text claims, and checks streaming completion. Crossing lettering
has an exclusive-assignment gate without an invented semantic row label.

```sh
python3 benchmark/eval/table_topology/generate.py --check
python3 -m unittest discover -s benchmark/eval/table_topology -p 'test_*.py'
python3 benchmark/eval/table_topology/verify.py \
  --cli zig-out/bin/pdf-parser --split dev \
  --output benchmark/eval/outputs/topology-order-2026-10-12/table-dev
```

After development and review, assess `--split holdout` into a new directory.
Evidence directories cannot be overwritten. Preserve failures and frozen truth;
do not retune the experiment using held-out results. Existing financial stress
floors remain required; topology comparison is opt-in through
`topology_required` in table truth. Comparator schema `0.4.0` adds separate
`table_count_accuracy` and `topology_accuracy` metrics; it does not change the
parser output schema.

Use the project-local monitor for every compiler invocation in this work:

```sh
python3 benchmark/eval/bounded_zig.py build -- --summary all
python3 benchmark/eval/bounded_zig.py test -- --summary all
```

It uses one task cache for local and global compiler objects, a 6 GiB observed
allocation budget, a 12 GiB free-space floor and two concurrent build jobs.
Allocation sampling can observe an overshoot; this is not a filesystem quota.
On a breach it terminates only its owned build process group and leaves logs,
receipts and caches intact. Evidence is stored outside compiler caches. Existing
toolchains and earlier verification evidence are retained.
