#!/usr/bin/env python3
"""Read-only parser comparisons against local reference fixtures.

Generated reductions and JSON evidence stay in ignored eval output paths.
This is a research harness, not a quality gate or a reference-model benchmark.
"""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
DEFAULT_REFERENCES = Path("/Volumes/External SSD/referencerepos")


def simple_pdf(content: str) -> bytes:
    stream = content.encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n"
        + stream + b"\nendstream",
    ]
    data = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n".encode()
    )
    return bytes(data)


def run(args: list[str]) -> dict:
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    return {"command": args, "exit_code": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def probe(executable: Path, pdf: Path, label: str, disable_ocr: bool = True) -> dict:
    native = run([str(executable), "extract", str(pdf)])
    adaptive_args = [str(executable), "extract-adaptive", "--input", str(pdf)]
    if disable_ocr:
        adaptive_args.append("--no-ocr")
    adaptive = run(adaptive_args + ["--format", "artifact-jsonl"])
    records = [json.loads(line) for line in adaptive["stdout"].splitlines()
               if line.strip()] if adaptive["exit_code"] == 0 else []
    spans = [r for r in records if r.get("record_type") == "span"]
    chunks = [r for r in records if r.get("record_type") == "rag_chunk"]
    routes = [r for r in records if r.get("record_type") == "route_trace"
              and r.get("trace_kind") in {"page_route", "region_route"}]
    return {
        "label": label, "pdf_path": str(pdf),
        "input_sha256": hashlib.sha256(pdf.read_bytes()).hexdigest(),
        "native_exit_code": native["exit_code"],
        "native_text": native["stdout"], "native_stderr": native["stderr"],
        "adaptive_exit_code": adaptive["exit_code"],
        "adaptive_stderr": adaptive["stderr"],
        "spans": [{k: r.get(k) for k in ("text", "bbox", "mcid", "source",
                   "confidence", "duplicate_count")} for r in spans],
        "chunks": [{k: r.get(k) for k in ("content", "text", "confidence")}
                   for r in chunks],
        "routes": [{k: r.get(k) for k in ("trace_kind", "route", "reasons",
                    "signals", "bbox")} for r in routes],
        "commands": [native["command"], adaptive["command"]],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--references", type=Path, default=DEFAULT_REFERENCES)
    parser.add_argument("--executable", type=Path, default=REPO / "zig-out/bin/pdf-parser")
    parser.add_argument("--output-dir", type=Path,
                        default=REPO / "benchmark/eval/outputs/reference-review-2026-10-09")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    reductions = {
        "same-mcid-distinct-lines": "/Span << /MCID 0 >> BDC BT /F1 12 Tf "
        "20 250 Td (FIRST) Tj 0 -24 Td (SECOND) Tj ET EMC",
        "distinct-lines-control": "BT /F1 12 Tf 20 250 Td (FIRST) Tj "
        "0 -24 Td (SECOND) Tj ET",
        "rotation-45-word-gap": "BT /F1 12 Tf "
        ".70710678 .70710678 -.70710678 .70710678 100 50 Tm "
        "(A) Tj 8.004 0 Td (B) Tj 11.340 0 Td (C) Tj 8.664 0 Td (D) Tj ET",
        "horizontal-word-gap-control": "BT /F1 12 Tf 1 0 0 1 100 50 Tm "
        "(A) Tj 8.004 0 Td (B) Tj 11.340 0 Td (C) Tj 8.664 0 Td (D) Tj ET",
        "ordinary-font-invisible-text": "BT /F1 12 Tf 20 250 Td "
        "(VISIBLE) Tj 0 -24 Td 3 Tr (INVISIBLE) Tj ET",
        "clipped-out-text": "q 0 0 10 10 re W n BT /F1 12 Tf "
        "100 200 Td (OUTSIDE-CLIP) Tj ET Q",
        "unique-page-title": "BT /F1 12 Tf 20 280 Td (Unique Page Title) Tj "
        "0 -45 Td (First body line with enough words) Tj "
        "0 -24 Td (Second body line with enough words) Tj "
        "0 -24 Td (Third body line with enough words) Tj "
        "0 -24 Td (Fourth body line with enough words) Tj ET",
    }
    evidence = []
    for name, content in reductions.items():
        path = args.output_dir / f"{name}.pdf"
        path.write_bytes(simple_pdf(content))
        evidence.append(probe(args.executable, path, name))
    fixture_dir = args.references / "docling/tests/data/pdf"
    for name in ("text_with_vector_glyphs.pdf", "text_with_vector_rule.pdf",
                 "invisible_text_layer.pdf", "vector_glyphs_in_figure.pdf"):
        path = fixture_dir / name
        if path.exists():
            evidence.append(probe(args.executable, path, f"docling/{name}"))
            if name in {"text_with_vector_glyphs.pdf", "invisible_text_layer.pdf"}:
                evidence.append(probe(args.executable, path,
                                      f"docling/{name}/ocr-enabled", disable_ocr=False))
    output = args.output_dir / "probes.json"
    output.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")
    for entry in evidence:
        print(json.dumps({"label": entry["label"],
                          "exit_code": entry["adaptive_exit_code"],
                          "native_text": entry["native_text"].strip(),
                          "adaptive_spans": [s["text"] for s in entry["spans"]],
                          "mcids": [s["mcid"] for s in entry["spans"]],
                          "duplicate_counts": [s["duplicate_count"] for s in entry["spans"]],
                          "page_routes": [{"route": r["route"], "reasons": r["reasons"],
                                           "hidden_ocr": (r["signals"] or {}).get("hidden_ocr")}
                                          for r in entry["routes"] if r["trace_kind"] == "page_route"]},
                         ensure_ascii=False))
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()
