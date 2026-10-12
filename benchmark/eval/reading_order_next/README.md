# Fresh reading-order experiment

This pack adds fourteen small PDFs in seven development/holdout families:
ruled table cells between prose, two-column sections that reset under a new
heading, reversed content-stream order, a gutter separator, rejected separators
crossing text or inside a graphic, an equivalent quarter-turn/CropBox/UserUnit
page, and a two-page continuation. Every text anchor is an independently
positioned PDF text object. Table cells contain separate objects and real rules.
The holdouts change anchor text and horizontal placement; these synthetic cases
do not establish performance on real documents.

The generator writes `freeze.json` with acceptance criteria and PDF/truth SHA256
before evaluation. It refuses to overwrite changed frozen data. Existing
reading-order packs and their failed promotion gates remain frozen. The default
extraction order remains `legacy`; this experiment does not promote graph order.

```sh
python3 benchmark/eval/reading_order_next/generate.py --check
python3 -m unittest discover -s benchmark/eval/reading_order_next -p 'test_*.py'
python3 benchmark/eval/reading_order_next/verify.py \
  --cli zig-out/bin/pdf-parser --eval-cli zig-out/bin/pdf-parser-eval \
  --split dev \
  --output benchmark/eval/outputs/topology-order-2026-10-12/reading-order-baseline
```

After implementation and independent review, evaluate `--split holdout` once
into a new evidence directory. Preserve diagnostic failures and failed public
order checks; do not revise truth or thresholds using heldout output. A failed
check exits nonzero and retains stdout, stderr, commands, binary hashes and
the freeze hash. The verifier requires an empty output directory so a later run
cannot replace earlier evidence. No compiler invocation is needed by this pack.

`report.json` scores anchor uniqueness and page assignment separately in spans
and blocks. Only block records supply public reading order. Page-local required
pairs and cross-page continuation pairs have separate scores. An optional eval
runner captures internal diagnostic scores independently, using graph truth
that excludes cross-page pairs because the current graph has page-local edges.
It reports unmet required-edge recall, invalid projection and cycles as explicit
diagnostic failures, separately from public-lane failures.
Diagnostic scores cannot qualify emitted order or document continuation.
Multiple anchors in one fused block can satisfy public order by text position;
internal graph anchor collisions remain visible in the separate diagnostic.

Stream checks require a first manifest, sequential page starts/finishes, page
artifacts inside their lifecycle, and one completed document end. Artifact JSONL
requires a first manifest and excludes streaming lifecycle records. Both reject
CLI errors and lifecycle error records. OCR is disabled in both public lanes and
the diagnostic lane. Stored evaluation output is ignored by Git and retained
outside the frozen pack.
