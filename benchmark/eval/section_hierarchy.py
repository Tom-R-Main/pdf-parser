#!/usr/bin/env python3
"""Exercise real CLI section ancestry with a small independent PDF construction.

Writes only to --output-dir (an ignored evaluation output directory by default).
These are deterministic controls, not real-document hierarchy qualification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def pdf_bytes(pages, outline):
    # Titles are ASCII controls. Each line is a separately positioned PDF object.
    objects = [b"", b"", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    page_ids = []
    for page in pages:
        page_id = len(objects) + 1
        page_ids.append(page_id)
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {page_id + 1} 0 R >>".encode())
        commands = []
        for line_index, (text, size) in enumerate(page):
            literal = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
            commands.append(f"BT /F1 {size} Tf 1 0 0 1 60 {740-line_index*65} Tm ({literal}) Tj ET")
        stream = "\n".join(commands).encode("ascii")
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream")
    outline_root = len(objects) + 1
    objects.append(b"")
    item_ids = list(range(len(objects) + 1, len(objects) + len(outline) + 1))
    # The outline is a nested single-child chain; level follows declared depth.
    for index, (title, page_index) in enumerate(outline):
        parent = outline_root if index == 0 else item_ids[index - 1]
        child = f" /First {item_ids[index+1]} 0 R /Last {item_ids[index+1]} 0 R /Count {len(outline)-index-1}" if index + 1 < len(outline) else ""
        objects.append(f"<< /Title ({title}) /Parent {parent} 0 R /Dest [{page_ids[page_index]} 0 R /Fit]{child} >>".encode())
    objects[outline_root - 1] = f"<< /Type /Outlines /First {item_ids[0]} 0 R /Last {item_ids[0]} 0 R /Count {len(outline)} >>".encode()
    objects[0] = f"<< /Type /Catalog /Pages 2 0 R /Outlines {outline_root} 0 R >>".encode()
    objects[1] = f"<< /Type /Pages /Count {len(pages)} /Kids [{' '.join(f'{value} 0 R' for value in page_ids)}] >>".encode()
    result = bytearray(b"%PDF-1.7\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        result.extend(f"{offset:010d} 00000 n \n".encode())
    result.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(result)


def blocks(records):
    return [record for record in records if record["record_type"] == "block"]


def assess(records, case):
    rows = blocks(records)
    by_text = {}
    for row in rows:
        by_text.setdefault(row["text"], []).append(row)
    if case == "cross-page":
        part = by_text["PART I"][0]
        scope = by_text["1. Scope"][0]
        definitions = by_text["1.1 Definitions"][0]
        assert scope["section"]["heading_level"] == 2
        assert scope["section"]["signal"] == "bookmark"
        assert by_text["next page body"][0]["section"]["ancestry"] == [part["block_id"], scope["block_id"]]
        assert definitions["section"]["heading_level"] == 3
        assert definitions["section"]["signal"] == "numbering"
        assert by_text["definition body"][0]["section"]["ancestry"] == [part["block_id"], scope["block_id"], definitions["block_id"]]
        assert any(len(row["section_ids"]) > 1 for row in records if row["record_type"] == "rag_chunk")
    else:
        assert by_text["1. Scope"][0]["section"]["heading_level"] == 3
        assert by_text["1. Scope"][0]["section"]["signal"] == "bookmark"
        assert len(by_text["Duplicate"]) == 2
        for row in by_text["Duplicate"]:
            assert row["section"]["heading_level"] is None
        assert by_text["Wrong target"][0]["section"]["signal"] != "bookmark"
        for text in ("2024 Annual report", "3:00 PM Session", "(a) list item"):
            assert by_text[text][0]["section"]["heading_level"] is None
    # Every section pointer is an existing heading block; all input text survives.
    by_id = {row["block_id"]: row for row in rows}
    for row in rows:
        for owner in row["section"]["ancestry"]:
            assert by_id[owner]["section"]["heading_level"] is not None
    return [{key: row[key] for key in ("block_id", "text", "page_index", "section", "source_map", "text_view")} for row in rows]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, default=Path("zig-out/bin/pdf-parser"))
    parser.add_argument("--output-dir", type=Path, default=Path("benchmark/eval/outputs/section-hierarchy"))
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    cases = {
        "cross-page": (
            [[("PART I", 20), ("1. Scope", 18), ("scope body", 12)],
             [("next page body", 12), ("1.1 Definitions", 18), ("definition body", 12)]],
            [("PART I", 0), ("Scope", 0)],
        ),
        "controls": (
            [[("1. Scope", 18), ("Duplicate", 18), ("Duplicate", 18), ("Wrong target", 18),
              ("2024 Annual report", 18), ("3:00 PM Session", 18), ("(a) list item", 12)],
             [("unrelated page", 12)]],
            [("Unmatched root", 0), ("Unmatched middle", 0), ("Scope", 0),
             ("Duplicate", 0), ("Wrong target", 1)],
        ),
    }
    report = {"binary_sha256": hashlib.sha256(args.cli.read_bytes()).hexdigest(), "cases": []}
    for name, (pages, outline) in cases.items():
        path = args.output_dir / f"{name}.pdf"
        path.write_bytes(pdf_bytes(pages, outline))
        observed = []
        for output_format in ("artifact-jsonl", "stream-jsonl"):
            command = [str(args.cli.resolve()), "extract-adaptive", "--input", str(path.resolve()), "--format", output_format, "--no-ocr"]
            run = subprocess.run(command, capture_output=True, text=True, check=False)
            (args.output_dir / f"{name}.{output_format}.jsonl").write_text(run.stdout)
            (args.output_dir / f"{name}.{output_format}.stderr").write_text(run.stderr)
            assert run.returncode == 0, (command, run.returncode, run.stderr)
            records = [json.loads(line) for line in run.stdout.splitlines() if line]
            observed.append(assess(records, name))
            report["cases"].append({"case": name, "format": output_format, "command": command, "passed": True})
        assert observed[0] == observed[1], f"{name}: batch/stream block annotation or exact source map drift"
    (args.output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Passed four real CLI section cases and batch/stream annotation/source-map identity")


if __name__ == "__main__":
    main()
