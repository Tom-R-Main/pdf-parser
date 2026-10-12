#!/usr/bin/env python3
"""Drive both public JSONL formats against frozen topology and ownership truth."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))
from table_compare import table_topology, topology_accuracy


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extraction_command(binary, pdf, output_format):
    return [str(binary), "extract-adaptive", "--no-ocr", "--input", str(pdf), "--format", output_format]


def score(records, truth, family, output_format="artifact-jsonl"):
    failures = []
    if not records or records[0].get("record_type") != "document_manifest":
        failures.append("manifest missing")
    if sum(r.get("record_type") == "document_manifest" for r in records) != 1:
        failures.append("manifest count mismatch")
    if records and records[0].get("page_count") != 1:
        failures.append("manifest page count mismatch")
    if output_format == "stream-jsonl":
        started = finished = ended = False
        completed_pages = []
        for record in records[1:]:
            kind = record.get("record_type")
            if ended:failures.append("output after document end")
            if kind == "page_started":
                if started or record.get("page_index") != 0 or record.get("status") != "running":
                    failures.append("invalid page start")
                started = True
            elif kind == "page_finished":
                if not started or finished or record.get("page_index") != 0 or record.get("status") != "completed":failures.append("invalid page finish")
                finished = True
                completed_pages.append(record.get("page_index"))
            elif kind == "document_finished":
                if not finished or record.get("status") != "completed" or completed_pages != [0]:failures.append("invalid document finish")
                ended = True
            elif kind in ("span", "block", "table") and (not started or finished or record.get("page_index") != 0):
                failures.append("artifact outside page lifecycle")
        if not (started and finished and ended):failures.append("incomplete stream")
    elif any(r.get("record_type") in ("page_started", "page_finished", "document_finished") for r in records):
        failures.append("stream lifecycle in batch output")
    tables = [r for r in records if r.get("record_type") == "table"]
    spans = {r["span_id"]:r for r in records if r.get("record_type") == "span"}
    if len(spans) != sum(r.get("record_type") == "span" for r in records):
        failures.append("duplicate span IDs")
    if len(tables) != len(truth):
        failures.append("table count mismatch")
    if family != "boundary-ownership" and topology_accuracy(tables, truth) != 1.0:
        failures.append("topology mismatch")
    expected_text = [c["text"] for t in truth for row in t["rows"] for c in row["cells"]]
    actual_cells = [c for t in tables for row in t["rows"] for c in row["cells"]]
    actual_text = [c["text"] for c in actual_cells]
    if family == "boundary-ownership":
        tokens = " ".join(actual_text).split()
        for label in expected_text:
            target = label.split()
            matches = sum(tokens[index:index+len(target)] == target
                          for index in range(len(tokens)-len(target)+1)) if target else 0
            if label and matches != 1:
                failures.append("crossing text duplicated or missing: "+label)
    elif actual_text != expected_text:
        failures.append("cell text mismatch (including blank versus zero)")
    owned = set()
    for cell in actual_cells:
        ids = cell.get("source_span_ids", [])
        if not cell["text"].strip():
            if ids:failures.append("empty cell claims source text")
            continue
        if not ids:
            failures.append("nonempty cell lacks source spans")
        source_text = []
        for sid in ids:
            if sid in owned:failures.append("source span has multiple cell owners")
            owned.add(sid)
            span = spans.get(sid)
            if span is None or span.get("page_index") != cell["page_index"]:
                failures.append("dangling or wrong-page source span")
            else:
                source_text.append(span["text"])
        if " ".join(source_text).split() != cell["text"].split():
            failures.append("source text disagrees with cell text")
    return dict(status="failed" if failures else "verified", failures=failures,
                tables=len(tables), cells=len(actual_cells))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--split", choices=["dev", "holdout"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    freeze = json.loads((ROOT/"freeze.json").read_text())
    for name, digest in freeze["files_sha256"].items():
        if sha(ROOT/name) != digest:raise ValueError("frozen corpus drift: "+name)
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.cli.resolve(strict=True)
    identity = dict(cli=str(binary), cli_sha256=sha(binary), freeze_sha256=sha(ROOT/"freeze.json"),
                    verifier_sha256=sha(Path(__file__)), head=subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip())
    (args.output/"identity.json").write_text(json.dumps(identity,indent=2)+"\n")
    results = []
    for case in json.loads((ROOT/"cases.json").read_text()):
        if case["split"] != args.split:continue
        truth = json.loads((ROOT/case["truth"]).read_text())
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            command = extraction_command(binary, ROOT/case["pdf"], fmt)
            result = subprocess.run(command,capture_output=True,timeout=30)
            name = case["id"]+"-"+fmt
            (args.output/(name+".jsonl")).write_bytes(result.stdout)
            (args.output/(name+".stderr")).write_bytes(result.stderr)
            records = []
            try:
                records = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
                report = score(records, truth, case["family"], fmt)
            except (ValueError, KeyError, TypeError) as error:
                report = dict(status="failed",failures=[str(error)])
            if result.returncode:
                report["status"]="failed";report["failures"].append("CLI failed")
            if any(r.get("errors") for r in records):
                report["status"]="failed";report["failures"].append("record errors")
            report.update(id=case["id"],format=fmt,command=command,exit_code=result.returncode)
            results.append(report)
    report = dict(identity=identity,results=results,verified=sum(r["status"]=="verified" for r in results),total=len(results))
    (args.output/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(dict(verified=report["verified"],total=report["total"])))
    return int(report["verified"] != report["total"])


if __name__ == "__main__":
    raise SystemExit(main())
