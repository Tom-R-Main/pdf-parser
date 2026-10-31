#!/usr/bin/env python3
"""Check LZW width transitions through native text and both public JSONL modes.

Literal-only streams use fixed width windows rather than a copy of the decoder
dictionary. An optional qpdf comparison checks the complete decoded bytes.
Generated PDFs and raw results stay in a fresh evidence directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def literal_lzw(data, early_change, reset_at=None):
    windows = (254, 766, 1790) if early_change else (255, 767, 1791)
    bits = []

    def emit(code, width):
        bits.extend((code >> shift) & 1 for shift in range(width - 1, -1, -1))

    def width(index):
        return 9 + sum(index >= boundary for boundary in windows)

    emit(256, 9)
    count = 0
    for index, byte in enumerate(data):
        if index == reset_at:
            emit(256, width(count))
            count = 0
        emit(byte, width(count))
        count += 1
    emit(257, width(count))
    bits.extend([0] * (-len(bits) % 8))
    return bytes(sum(bits[index + bit] << (7 - bit) for bit in range(8))
                 for index in range(0, len(bits), 8))


def make_pdf(payload, filters, params, extra_objects=(), form=False):
    resources = b"/Font << /F1 4 0 R >>" + (b" /XObject << /Fm1 6 0 R >>" if form else b"")
    stream = f"<< /Length {len(payload)} /Filter {filters} {params}".encode()
    if form:
        stream += b" /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >>"
    stream += b" >>\nstream\n" + payload + b"\nendstream"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << " + resources + b" >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length 8 >>\nstream\n/Fm1 Do\n\nendstream" if form else stream,
    ]
    if form:
        objects.append(stream)
    objects.extend(extra_objects)
    output, offsets = bytearray(b"%PDF-1.7\n"), []
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    for offset in offsets:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return output


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "zig-out/bin/pdf-parser")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qpdf", help="optional independent decoded-byte oracle executable")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {"cli_sha256": digest(args.cli), "harness_sha256": digest(Path(__file__)),
              "decoder_sha256": digest(ROOT / "src/decompress.zig"),
              "resolver_sha256": digest(ROOT / "src/pagetree.zig"), "runs": [], "oracles": []}
    for name, early, chain, reset, entry, style in (
        ("default", 1, False, None, "", "direct"),
        ("null-default", 1, False, None, "/EarlyChange null", "direct"),
        ("early-one", 1, False, None, "/EarlyChange 1", "direct"),
        ("early-zero", 0, False, None, "/EarlyChange 0", "direct"),
        ("chain-predictor-one", 1, True, None, "/EarlyChange 1", "direct"),
        ("chain-predictor-zero", 0, True, None, "/EarlyChange 0", "direct"),
        ("reset-one", 1, False, 2100, "/EarlyChange 1", "direct"),
        ("reset-zero", 0, False, 2100, "/EarlyChange 0", "direct"),
        ("indirect-one", 1, False, None, "/EarlyChange 6 0 R", "entry"),
        ("indirect-zero", 0, False, None, "/EarlyChange 6 0 R", "entry"),
        ("indirect-null", 1, False, None, "/EarlyChange 6 0 R", "null-entry"),
        ("indirect-nested-zero", 0, False, None, "", "nested"),
        ("indirect-params-zero", 0, False, None, "", "params"),
        ("indirect-array-zero", 0, True, None, "", "array"),
        ("indirect-form-zero", 0, False, None, "/EarlyChange 7 0 R", "form"),
    ):
        expected = f"LZW {name} source retained"
        content = b"%" + b"p" * 3200 + f"\nBT /F1 12 Tf 40 700 Td ({expected}) Tj ET\n".encode()
        source = content
        if chain:
            source = bytes([content[0]] + [(byte - content[index - 1]) % 256 for index, byte in enumerate(content) if index])
        encoded = literal_lzw(source, early, reset)
        filters = "/LZWDecode"
        params = f"/DecodeParms << {entry} >>"
        if chain:
            encoded = encoded.hex().encode() + b">"
            filters = "[/ASCIIHexDecode /LZWDecode]"
            params = f"/DecodeParms [null << {entry} /Predictor 2 /Columns {len(content)} >>]"
        extra = []
        if style in ("entry", "form"):
            extra = [str(early).encode()]
        elif style == "null-entry":
            extra = [b"null"]
        elif style == "nested":
            params = "/DecodeParms 6 0 R"
            extra = [b"<< /EarlyChange 7 0 R >>", b"0"]
        elif style == "params":
            params = "/DecodeParms 6 0 R"
            extra = [b"<< /EarlyChange 0 >>"]
        elif style == "array":
            params = "/DecodeParms 6 0 R"
            extra = [b"[null 7 0 R]", f"<< /EarlyChange 8 0 R /Predictor 2 /Columns {len(content)} >>".encode(), b"0"]
        path = args.output / f"{name}.pdf"
        path.write_bytes(make_pdf(encoded, filters, params, extra, style == "form"))
        if args.qpdf:
            command = [args.qpdf, "--show-object=6" if style == "form" else "--show-object=5", "--filtered-stream-data", str(path)]
            result = subprocess.run(command, capture_output=True, timeout=15)
            (args.output / f"{name}.qpdf.bin").write_bytes(result.stdout)
            (args.output / f"{name}.qpdf.stderr").write_bytes(result.stderr)
            report["oracles"].append({"command": command, "exit_code": result.returncode,
                                      "passed": result.returncode == 0 and result.stdout == content})
        for fmt in ("native", "artifact-jsonl", "stream-jsonl"):
            command = [str(args.cli.resolve()), "extract", "--fast", str(path)] if fmt == "native" else [
                str(args.cli.resolve()), "extract-adaptive", "--input", str(path), "--no-ocr", "--format", fmt]
            result = subprocess.run(command, capture_output=True, text=True, timeout=15)
            stem = args.output / f"{name}.{fmt}"
            stem.with_suffix(stem.suffix + ".stdout").write_text(result.stdout)
            stem.with_suffix(stem.suffix + ".stderr").write_text(result.stderr)
            failures = []
            if result.returncode:
                failures.append(f"exit {result.returncode}")
            if fmt == "native":
                if result.stdout.strip() != expected:
                    failures.append("native text mismatch")
            else:
                try:
                    records = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
                    spans = [r for r in records if r.get("record_type") == "span"]
                    if not records or records[0].get("record_type") != "document_manifest":
                        failures.append("missing manifest")
                    if " ".join(r.get("text", "") for r in spans) != expected or any(r.get("page_index") != 0 for r in spans):
                        failures.append("span text or page identity mismatch")
                    if any(r.get("errors") for r in records):
                        failures.append("artifact errors")
                    if fmt == "stream-jsonl" and (not records or records[-1].get("record_type") != "document_finished" or records[-1].get("status") != "completed"):
                        failures.append("missing completed stream")
                except json.JSONDecodeError:
                    failures.append("invalid JSONL")
            report["runs"].append({"case": name, "format": fmt, "command": command,
                                   "input_sha256": digest(path), "exit_code": result.returncode, "failures": failures})
    report["passed"] = all(not r["failures"] for r in report["runs"]) and all(r["passed"] for r in report["oracles"])
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "runs": len(report["runs"]),
                      "oracles": len(report["oracles"]), "failures": [r for r in report["runs"] if r["failures"]]}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
