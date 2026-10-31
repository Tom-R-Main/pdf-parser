#!/usr/bin/env python3
"""Public CLI regressions for bounded section and outline parsing."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def make_pdf(links, heading="Scope"):
    text = f"BT /F1 18 Tf 1 0 0 1 60 740 Tm ({heading}) Tj ET\nBT /F1 12 Tf 1 0 0 1 60 675 Tm (BODY SENTINEL) Tj ET".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 6120 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        f"<< /Length {len(text)} >>\nstream\n".encode() + text + b"\nendstream",
        f"<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count {len(links)} >>".encode(),
    ]
    for child, sibling in links:
        child_text = f" /First {7+child} 0 R /Last {7+child} 0 R /Count 1" if child is not None else ""
        sibling_text = f" /Next {7+sibling} 0 R" if sibling is not None else ""
        objects.append(f"<< /Title (Unmatched bookmark) /Parent 6 0 R /Dest [3 0 R /Fit]{child_text}{sibling_text} >>".encode())
    data = bytearray(b"%PDF-1.7\n")
    offsets = []
    for index, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "zig-out/bin/pdf-parser")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    cases = [
        ("normal", [(None, None)], "Scope"),
        ("deep-numbering", [(None, None)], "1." * 256 + " Heading"),
        ("self-child", [(0, None)], "Scope"),
        ("child-cycle", [(1, None), (0, None)], "Scope"),
        ("sibling-cycle", [(None, 1), (None, 0)], "Scope"),
        ("deep-outline", [(i + 1 if i < 79 else None, None) for i in range(80)], "Scope"),
    ]
    report = {"cli_sha256": hashlib.sha256(args.cli.read_bytes()).hexdigest(),
              "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "runs": []}
    for name, links, heading in cases:
        path = args.output / f"{name}.pdf"
        path.write_bytes(make_pdf(links, heading))
        for output_format in ("artifact-jsonl", "stream-jsonl"):
            command = [str(args.cli.resolve()), "extract-adaptive", "--input", str(path.resolve()), "--no-ocr", "--format", output_format]
            failures = []
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                stdout, stderr, code = result.stdout, result.stderr, result.returncode
            except subprocess.TimeoutExpired as error:
                stdout = (error.stdout or b"").decode(errors="replace")
                stderr = (error.stderr or b"").decode(errors="replace")
                code = None
                failures.append("extraction exceeded timeout")
            (args.output / f"{name}.{output_format}.jsonl").write_text(stdout)
            (args.output / f"{name}.{output_format}.stderr").write_text(stderr)
            if code != 0:
                failures.append(f"exit code {code}")
            try:
                records = [json.loads(line) for line in stdout.splitlines()]
            except ValueError:
                records = []
                failures.append("malformed JSONL")
            if not records or records[0].get("record_type") != "document_manifest":
                failures.append("missing manifest")
            spans = [r for r in records if r.get("record_type") == "span"]
            if not any("BODY SENTINEL" in r["text"] for r in spans):
                failures.append("body text lost")
            if output_format == "stream-jsonl" and (not records or records[-1].get("record_type") != "document_finished"):
                failures.append("missing stream closeout")
            if name == "deep-numbering":
                matches = [r for r in records if r.get("record_type") == "block" and r.get("text") == heading]
                if len(matches) != 1 or matches[0]["section"]["heading_level"] != 12 or matches[0]["section"]["signal"] != "numbering":
                    failures.append("numbering failed to retain exact text and bounded depth")
            report["runs"].append({"case": name, "format": output_format, "command": command,
                                   "input_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                   "exit": code, "failures": failures})
    report["passed"] = all(not run["failures"] for run in report["runs"])
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "runs": len(report["runs"]),
                      "failures": [run for run in report["runs"] if run["failures"]]}, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
