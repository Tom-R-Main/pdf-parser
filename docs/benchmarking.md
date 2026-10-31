# Benchmarking and evaluation

Run these commands from the repository root. Build first and put `zig-out/bin`
on your shell PATH when using the short `pdf-parser` executable name.

Performance claims should be generated from fast artifacts and checked
against byte-stable output, not copied from one-off local timings. Build the
optimized parser once, then profile the extraction lanes separately:

```bash
zig build -Doptimize=fast --summary all
.venv/bin/python benchmark/eval/profile_lanes.py \
  --manifest benchmark/eval/large/manifest.tsv \
  --lanes native-text,adaptive-artifact-jsonl,adaptive-stream-jsonl,ocr-routed \
  --repeat 3 \
  --hash-output \
  --output benchmark/eval/outputs/profile/baseline-large.jsonl
.venv/bin/python benchmark/eval/analyze_baseline.py \
  --profile-jsonl benchmark/eval/outputs/profile/baseline-large.jsonl \
  --manifest benchmark/eval/large/manifest.tsv \
  --output benchmark/eval/outputs/profile/baseline-report.json \
  --table-output benchmark/eval/outputs/profile/baseline-report.md
```

Use the tiny checked-in corpus for correctness gates and the ignored large
cache for performance work. The large manifest is designed to cover 100-page,
1k-page, image-heavy, object-stream-heavy, encrypted, and table-heavy PDFs
without committing large third-party documents.

Recorded local ReleaseFast optimization checks on Apple M4 Pro kept output hashes
unchanged while improving the measured hot paths:

| Optimization | Fixture / lane | Before | After |
|--------------|----------------|-------:|------:|
| Reused decoded content streams | PDF Reference 1k / native text | 461.0ms | 329.2ms |
| Indexed route/provenance lookups | table-heavy SEC / artifact JSONL | 731.6ms | 555.1ms |
| Bucketed body-font estimation | table-heavy SEC / native text | 232.3ms | 224.6ms |
| Bucketed body-font estimation | table-heavy SEC / artifact JSONL | 480.2ms | 464.8ms |

Treat these as local regression evidence, not universal parser rankings. For
external comparisons, use `benchmark/eval/compare.py --ensure-releasefast` so
the `pdf-parser` lane runs `zig-out/bin/pdf-parser-eval` instead of rebuilding
inside each document timing.

## Evaluation Corpus

The checked-in evaluation corpus is intentionally small and deterministic, with
manifest metadata for source notes, redistribution status, SHA256, expected route
counts, and optional ground-truth labels.

```bash
zig build eval-corpus
zig build eval -- --adaptive \
  --ocr-executable tesseract \
  --ocr-rasterizer pdftoppm \
  --manifest benchmark/eval/corpus/manifest.tsv
zig build benchmark-eval
pdf-parser benchmark \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --suite-id tiny-corpus \
  --tools pdf-parser:adaptive,pdf-parser:native \
  --thresholds benchmark/eval/thresholds.json \
  --output benchmark/eval/outputs/scorecards/tiny-corpus.json \
  --jsonl benchmark/eval/outputs/scorecards/tiny-corpus.records.jsonl
.venv/bin/python benchmark/eval/compare.py \
  --pdf-parser-adaptive \
  --tools pdf-parser,pymupdf,pypdfium2,pdfplumber \
  --ensure-releasefast \
  --manifest benchmark/eval/corpus/manifest.tsv
.venv/bin/python benchmark/eval/structural_compare.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --output /tmp/pdf-parser-structural.jsonl
.venv/bin/python benchmark/eval/font_compare.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --output /tmp/pdf-parser-font-diff.jsonl
.venv/bin/python benchmark/eval/render_oracle.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --category visual_truth \
  --output /tmp/pdf-parser-render-oracle.jsonl
.venv/bin/python benchmark/eval/table_compare.py \
  --manifest benchmark/eval/table_stress/manifest.tsv \
  --output /tmp/pdf-parser-table-stress.jsonl
python3 benchmark/eval/ocr_form_quality.py \
  --output /tmp/pdf-parser-ocr-form-quality.json
python3 benchmark/eval/ocr_hard_document_quality.py \
  --output /tmp/pdf-parser-ocr-hard-document-quality.json
python3 benchmark/eval/ocr_hard_document_quality.py \
  --pdf benchmark/eval/corpus/scanned_typewritten/jpx-public-domain-map-cover.pdf \
  --truth benchmark/eval/ground_truth/ocr_text/scanned_typewritten/jpx-public-domain-map-cover.json \
  --output /tmp/pdf-parser-ocr-jpx-hard-document-quality.json
.venv/bin/python benchmark/eval/fetch_large_corpus.py --dry-run
.venv/bin/python benchmark/eval/run_baseline.py --large
.venv/bin/python benchmark/eval/profile_lanes.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --lanes native-text,adaptive-artifact-jsonl \
  --output /tmp/pdf-parser-profile.jsonl
.venv/bin/python benchmark/eval/analyze_baseline.py \
  --compare-jsonl benchmark/eval/outputs/comparison/baseline.jsonl \
  --profile-jsonl /tmp/pdf-parser-profile.jsonl \
  --manifest benchmark/eval/large/manifest.tsv \
  --output /tmp/pdf-parser-baseline-report.json \
  --table-output /tmp/pdf-parser-baseline-report.md
```

Current fixture classes include clean born-digital text, academic two-column
layout, scientific formulas, synthetic image-only scans, public-domain real
JBIG2 and JPX scans, mixed native/scan pages,
financial tables, AcroForms, weird-font cases, visual truth fixtures, and
corrupt/adversarial PDFs.
`benchmark/eval/font_compare.py` runs the weird-font subset against
`pdf-parser`, PyMuPDF, and pypdfium2; use it as differential accuracy evidence,
not as a claim that the Python tools are universal ground truth. The Sleisenger
reductions cover standard Symbol glyph names and family-scoped MathematicalPi
private names with exact Unicode expectations. The `benchmark-eval` build step
also requires exact native text across every checked-in hard-font fixture.
Financial
table truth can assert cell text plus `rowspan`, `colspan`, `role`, `page`, and
bbox-aware provenance. Form truth asserts field name/type/value sequences.
Formula truth can assert both text and simple structure records.

`benchmark/eval/render_oracle.py` is an optional render-backed differential
lane. It runs `extract-adaptive --format artifact-jsonl --debug-assets-dir`,
renders pages with Poppler `pdftoppm` by default, maps span/block/table/route
geometry into raster pixels using the emitted SVG overlay viewBox, and reports
coverage signals for rotated pages, clipped text, invisible OCR-like layers,
ruled-table pixels, and mixed image regions. Use `--renderer all` to include
optional pypdfium2 and `mutool draw` lanes, and `--materialize-dir` to write
rendered pages or low-coverage crops for review. Generated PNGs and crops are
local artifacts only; they should not be committed.

`benchmark/eval/pdfium-rasterizer` is an optional PDFium-backed adapter for the
same one-page `pdftoppm` subprocess contract used by OCR. It uses the local
virtual environment when present and otherwise requires `pypdfium2` in the
active Python environment:

```bash
pdf-parser extract --adaptive --format artifact-jsonl \
  --ocr-executable tesseract \
  --ocr-rasterizer benchmark/eval/pdfium-rasterizer \
  scanned.pdf
```

This keeps native extraction deterministic while delegating JBIG2, JPX/JPEG2000,
Type3, and other render-completeness cases to PDFium when a raster-backed route
is explicitly selected. It does not make PDFium a text-extraction authority.

`benchmark/eval/table_stress` is a separate checked-in financial table stress
pack. It contains small synthetic reductions for SEC statement continuations,
borderless bank statements, wrapped invoice totals, procurement nested headers,
and legal schedules drawn out of order. Use `benchmark/eval/table_compare.py`
to compare structured table artifacts against PyMuPDF `Page.find_tables()` and
optional pdfplumber lanes. The stress runner reports cell text, role, bbox IoU,
numeric, continuation, and source-span coverage metrics where the truth sidecar
provides labels. Larger source PDFs and redistribution-unclear page reductions
belong under ignored benchmark cache paths, not git.
The OCR form quality gate records the exact OCR and rasterizer versions and
reports token precision and F1 as well as recall, so duplicate layout/OCR
layers cannot pass by repeating all expected tokens. Date separator glyph loss
is normalized before semantic token scoring. The gate also requires exact
date/vendor/amount row tuples, row count, individual columns, and total recovery.

`pdf-parser benchmark` is the product-facing corpus runner. It emits a full
scorecard JSON plus optional record-oriented JSONL with `benchmark_run`,
`benchmark_lane`, `benchmark_document_result`, `benchmark_category_summary`,
`benchmark_regression`, and `benchmark_scorecard` records. Tool lanes are
neutral: use `pdf-parser:native`, `pdf-parser:adaptive`, or
`command:<id>=<command template with {pdf}>`. `--candidate-command` and
`--baseline-command` compare two pdf-parser-compatible executables and
`--fail-on-regression` makes the scorecard usable as a CI ingestion gate.
Benchmark schema `0.3.0` adds absolute `minimum` and `maximum` thresholds for
homogeneous capability manifests, so a standalone candidate or two equally
degraded versions cannot pass on relative comparison alone. Checked-in examples
live under `benchmark/eval/gates/`.

For structural parser hardening, use the qpdf differential lane:

```bash
pdf-parser check --format json doc.pdf
pdf-parser inspect structure --format json doc.pdf
.venv/bin/python benchmark/eval/structural_compare.py \
  --manifest benchmark/eval/corpus/manifest.tsv \
  --output benchmark/eval/outputs/structural/tiny-corpus.jsonl
```

The structural report records input hash, page count, xref/trailer summary,
encryption presence, stable diagnostic codes, recovery actions, and
`status: ok|recovered|failed`. qpdf remains an external oracle for
benchmarking and fixture derivation; extraction never shells out to qpdf.

`benchmark/eval/corpus` is the tiny checked-in correctness and regression
corpus. Large public or private PDFs belong under ignored
`benchmark/eval/raw_cache/large`; use `benchmark/eval/fetch_large_corpus.py` to
download/derive local performance fixtures and `benchmark/eval/profile_lanes.py`
to measure native text, adaptive artifact JSONL, streaming JSONL, and OCR-routed
lanes before doing parser optimization. The profiler keeps OCR isolated by
default: adaptive JSONL lanes pass `--no-ocr`, while `ocr-routed` invokes
Tesseract and can be bounded with `--ocr-pages`. OCR routes first use 200 DPI
with PSM 6 and grayscale rasterization. Empty or low-quality results may retry
once at 300 DPI with PSM 11, after which the parser selects deterministically
from the recorded attempts. Use the OCR CLI controls to compare policies or
`--ocr-color` when comparing against the older RGB raster path. Add
`--hash-output` during optimization
validation runs when byte-for-byte output stability matters; hashes are computed
after the timed subprocess exits, and the analyzer summarizes hash stability
when hashes are present. `benchmark/eval/analyze_baseline.py`
turns comparator and profiler JSONL into grouped JSON/Markdown reports and
records whether manifest PDFs are locally present. It also ranks measured
optimization candidates and next actions, so the next slice is chosen from
evidence instead of hunches. `benchmark/eval/run_baseline.py --large` runs the
whole fast baseline workflow and skips large profiling until the ignored
cache is populated.
