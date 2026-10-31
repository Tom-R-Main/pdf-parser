#!/usr/bin/env python3
"""Exercise logical-table continuation through both public JSONL formats.

Generated PDFs and raw results stay in a new caller-selected evidence directory.
This tests continuation policy, not real-document table extraction accuracy.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("drawing", ROOT / "benchmark/eval/table_topology/generate.py")
drawing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drawing)
BASE = ["Account", "Current", "Previous", "Budget"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def table(headers, top=720):
    xs, ys = [60, 200, 310, 420, 550], [top, top-40, top-80, top-120]
    commands = ["0.5 w"]
    commands += [f"{x} {ys[-1]} m {x} {ys[0]} l S" for x in xs]
    commands += [f"{xs[0]} {y} m {xs[-1]} {y} l S" for y in ys]
    for row, values in enumerate([headers, ["Cash", "10", "11", "12"], ["Debt", "20", "21", "22"]]):
        commands += [drawing.text(value, xs[column]+8, ys[row]-22) for column, value in enumerate(values)]
    return commands


def pdf(pages):
    kids = " ".join(f"{4+index*2} 0 R" for index in range(len(pages)))
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               f"<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>".encode(),
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    for index, commands in enumerate(pages):
        stream = ("\n".join(commands)+"\n").encode()
        objects += [f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {5+index*2} 0 R /Resources << /Font << /F1 3 0 R >> >> >>".encode(),
                    b"<< /Length "+str(len(stream)).encode()+b" >>\nstream\n"+stream+b"endstream"]
    output, offsets = bytearray(b"%PDF-1.4\n"), [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode()+obj+b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(output)


def cases():
    yield "matching-chain", [table(BASE), table([s.upper() for s in BASE]), table(BASE)], [0, 0, 0]
    yield "partial-header", [table(BASE), table([*BASE[:3], "Forecast"])], [0, 1]
    yield "different-header", [table(BASE), table(["Category", "Target", "Actual", "Variance"])], [0, 1]
    yield "page-gap", [table(BASE), [drawing.text("Intervening narrative", 60, 720)], table(BASE)], [0, 1]
    yield "intervening-table", [table(BASE)+table(["Category", "Target", "Actual", "Variance"], 480), table(BASE)], [0, 1, 2]


def evaluate(cli, output):
    output.mkdir(parents=True, exist_ok=False)
    report = {"cli_sha256": digest(cli), "harness_sha256": digest(Path(__file__)),
              "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "source_sha256": {name: digest(ROOT / name) for name in
                                ("src/table_continuation.zig", "src/adaptive.zig", "src/stream.zig")},
              "cases": []}
    for name, pages, expected_groups in cases():
        path = output / f"{name}.pdf"
        path.write_bytes(pdf(pages))
        entry = {"id": name, "input_sha256": digest(path), "formats": {}, "failures": []}
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            command = [str(cli), "extract-adaptive", "--input", str(path), "--no-ocr", "--format", fmt]
            run = subprocess.run(command, capture_output=True, text=True, timeout=30)
            (output / f"{name}.{fmt}.jsonl").write_text(run.stdout)
            (output / f"{name}.{fmt}.stderr").write_text(run.stderr)
            result = {"command": command, "exit_code": run.returncode, "tables": []}
            entry["formats"][fmt] = result
            if run.returncode:
                entry["failures"].append(f"{fmt}: CLI exited {run.returncode}")
                continue
            records = [json.loads(line) for line in run.stdout.splitlines() if line.strip()]
            if not records or records[0].get("record_type") != "document_manifest":
                entry["failures"].append(f"{fmt}: missing first manifest")
            if any(r.get("errors") for r in records):
                entry["failures"].append(f"{fmt}: lifecycle errors")
            if fmt == "stream-jsonl" and (records[-1].get("record_type") != "document_finished" or records[-1].get("status") != "completed"):
                entry["failures"].append("stream-jsonl: missing successful completion")
            tables = [r for r in records if r.get("record_type") == "table"]
            result["tables"] = [{key: t.get(key) for key in ("table_id", "logical_table_id", "table_part_index", "continued_from_table_id", "continued_to_table_id", "page_index", "column_count")} for t in tables]
            if len(tables) != len(expected_groups):
                entry["failures"].append(f"{fmt}: expected {len(expected_groups)} tables, found {len(tables)}")
                continue
            for index, group in enumerate(expected_groups):
                t = tables[index]
                expected_from = tables[index-1]["table_id"] if index and expected_groups[index-1] == group else None
                expected_part = sum(previous == group for previous in expected_groups[:index])
                if t.get("logical_table_id") != tables[group].get("logical_table_id") or t.get("table_part_index") != expected_part or t.get("continued_from_table_id") != expected_from:
                    entry["failures"].append(f"{fmt}: wrong continuation at table {index}")
                for other in range(index):
                    if (t.get("logical_table_id") == tables[other].get("logical_table_id")) != (group == expected_groups[other]):
                        entry["failures"].append(f"{fmt}: incorrect grouping {other}/{index}")
                if fmt == "artifact-jsonl":
                    expected_to = tables[index+1]["table_id"] if index+1 < len(tables) and expected_groups[index+1] == group else None
                    if t.get("continued_to_table_id") != expected_to:
                        entry["failures"].append(f"{fmt}: wrong forward link at table {index}")
        left, right = (entry["formats"][fmt]["tables"] for fmt in ("artifact-jsonl", "stream-jsonl"))
        comparable = lambda tables: [{k: v for k, v in t.items() if k != "continued_to_table_id"} for t in tables]
        if comparable(left) != comparable(right):
            entry["failures"].append("formats disagree on table identity or backward links")
        report["cases"].append(entry)
    report["passed"] = all(not case["failures"] for case in report["cases"])
    (output / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "zig-out/bin/pdf-parser")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = evaluate(args.cli.resolve(), args.output.resolve())
    print(json.dumps({"passed": report["passed"], "cases": [{"id": c["id"], "failures": c["failures"]} for c in report["cases"]]}, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
