# Recorded external-OCR routing

Recorded external OCR is a separate, explicit downstream-routing gate:

```sh
zig build && zig build benchmark-eval
python3 -m unittest discover -s benchmark/eval -p 'test_recorded_ocr.py'
python3 benchmark/eval/recorded_ocr.py \
  --fixture benchmark/eval/recorded_ocr/jpx-mac-2026-11-01/fixture.json \
  --output benchmark/eval/outputs/recorded-ocr-run
```

The generic harness uses the existing executable seams, with dimension-only
PNG headers and hash-verified recorded TSV. Its strict evaluator command loads
the original corpus metadata (JPX: 1 OCR page, 4 table and 6 formula regions),
without counter overrides. A changed, valid TSV must reach `RouteCountMismatch`;
a corrupt TSV must fail provenance validation. Every command, result and
provider invocation is retained in the report and logs.

The JPX fixture records one macOS Tesseract 5.5.2 / Poppler 26.02.0 capture at
300 DPI, PSM 11, grayscale, with model/PDF/TSV hashes and geometry in
`recorded_ocr/jpx-mac-2026-11-01/capture.json`. The CLI uses that single attempt.
The evaluator's default bounded retry receives an explicitly synthetic empty
200 DPI / PSM 6 primary followed by the exact captured 300 DPI / PSM 11 TSV.
This controlled replay does not reconstruct historical retry selection, process
pixels, qualify the recorded tools, or establish live Linux OCR route counts.
Its report states `live_ocr_qualified: false`.

Live OCR remains independently checked by `ocr_hard_document_quality.py` and
the CI `adaptive-ocr` job, using real Tesseract and rasterization with the
existing semantic floors and pinned-version guards. A strict live corpus
route mismatch remains a failure; replay never substitutes into that lane.

