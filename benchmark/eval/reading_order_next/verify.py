#!/usr/bin/env python3
"""Score public block order independently from optional internal graph diagnostics."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(text):
    return " ".join(text.split())


def occurrences(text, anchor):
    return list(re.finditer(r"(?<!\w)" + re.escape(normalize(anchor)) + r"(?!\w)", normalize(text)))


def score_records(records, truth, output_format, returncode=0):
    failures = []
    if returncode != 0:
        failures.append(f"CLI exit status {returncode}")
    expected_pages = sorted({node["page_index"] for node in truth["nodes"]})
    if not records or records[0].get("record_type") != "document_manifest":
        failures.append("document_manifest must be first")
    if sum(r.get("record_type") == "document_manifest" for r in records) != 1:
        failures.append("expected one document_manifest")
    elif records[0].get("page_count") != len(expected_pages):
        failures.append("manifest page_count mismatch")
    for record in records:
        if record.get("record_type") in ("document_manifest", "document_finished", "page_finished") and record.get("errors"):
            failures.append(f"{record.get('record_type')} contains errors")
    if output_format == "stream-jsonl":
        active = None
        started, finished = [], []
        ended = False
        for index, record in enumerate(records):
            kind, page = record.get("record_type"), record.get("page_index")
            if ended:
                failures.append("records after document_finished")
            if kind == "page_started":
                if active is not None or page in started or page != len(started):
                    failures.append("invalid page_started sequence")
                if record.get("status") != "running":
                    failures.append("page_started not running")
                active = page
                started.append(page)
            elif kind == "page_finished":
                if active != page or active is None or page in finished:
                    failures.append("page_finished without matching start")
                if record.get("status") != "completed":
                    failures.append("page_finished not completed")
                active = None
                finished.append(page)
            elif kind in ("span", "block") and (active is None or page != active):
                failures.append("page artifact outside active page lifecycle")
            elif kind == "document_finished":
                if active is not None or index != len(records) - 1:
                    failures.append("invalid document_finished placement")
                if record.get("status") != "completed":
                    failures.append("document_finished not completed")
                ended = True
        if started != expected_pages or finished != expected_pages or not ended:
            failures.append("incomplete stream lifecycle")
    else:
        if any(r.get("record_type") in ("page_started", "page_finished", "document_finished") for r in records):
            failures.append("unexpected stream lifecycle in artifact-jsonl")
    anchors = {}
    block_positions = {}
    # Both surfaces are scored separately; counting spans and blocks together would duplicate every anchor.
    for kind in ("span", "block"):
        items = [record for record in records if record.get("record_type") == kind]
        anchors[kind] = {}
        for node in truth["nodes"]:
            hits = [(index, match.start(), item.get("page_index"))
                    for index, item in enumerate(items) for match in occurrences(item.get("text", ""), node["text_anchor"])]
            anchors[kind][node["id"]] = dict(count=len(hits), expected_page=node["page_index"], observed_pages=[h[2] for h in hits])
            if len(hits) != 1 or hits[0][2] != node["page_index"]:
                failures.append(f"{kind} anchor {node['id']}: expected one occurrence on page {node['page_index']}, found {hits}")
            elif kind == "block":
                block_positions[node["id"]] = hits[0][:2]

    def precedence(edges):
        result = []
        for left, right in edges:
            passed = left in block_positions and right in block_positions and block_positions[left] < block_positions[right]
            result.append(dict(from_id=left, to_id=right, passed=passed))
        return dict(total=len(result), passed=sum(pair["passed"] for pair in result), pairs=result)

    local = precedence(truth["page_local_precedence"])
    document = precedence(truth["document_precedence"])
    if local["passed"] != local["total"]:
        failures.append("emitted page-local order inversion or unresolved anchor")
    if document["passed"] != document["total"]:
        failures.append("emitted document order inversion or unresolved anchor")
    return dict(verdict="failed" if failures else "verified", failures=failures, anchors=anchors,
                emitted_page_local=local, emitted_document=document,
                graph_diagnostics="not inferred from public extraction output")


def parse_records(data):
    records = []
    for number, line in enumerate(data.splitlines(), 1):
        if not line.strip():
            continue
        record = json.loads(line)
        if not isinstance(record, dict) or not isinstance(record.get("record_type"), str):
            raise ValueError(f"Invalid JSONL record at line {number}")
        if record["record_type"] in ("span", "block") and (
            not isinstance(record.get("text"), str) or type(record.get("page_index")) is not int
        ):
            raise ValueError(f"Invalid text/page artifact at line {number}")
        records.append(record)
    return records


def score_diagnostic(rows, doc_id):
    if len(rows) != 1 or rows[0].get("doc_id") != doc_id:
        return dict(verdict="failed", failures=["diagnostic document identity/count mismatch"])
    metrics = rows[0].get("metrics", {})
    expected = dict(reading_graph_required_recall=1.0, reading_graph_valid_projection=1.0,
                    reading_graph_cycle_rate=0.0)
    failures = [f"{name}: expected {target}, observed {metrics.get(name)}"
                for name, target in expected.items() if metrics.get(name) != target]
    return dict(verdict="failed" if failures else "verified", failures=failures,
                expected=expected, observed={name: metrics.get(name) for name in expected})


def check_freeze():
    freeze_path = ROOT / "freeze.json"
    freeze = json.loads(freeze_path.read_text())
    for name, expected in freeze["sha256"].items():
        path = ROOT / name
        if not path.is_file() or sha(path) != expected:
            raise ValueError(f"Frozen file changed: {name}")
    return sha(freeze_path)


def execute(command, stem, timeout):
    try:
        completed = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
        code, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        code, stdout, stderr = -1, error.stdout or b"", (error.stderr or b"") + b"\nVerifier timeout\n"
    except OSError as error:
        code, stdout, stderr = -1, b"", str(error).encode()
    stem.with_suffix(".stdout.jsonl").write_bytes(stdout)
    stem.with_suffix(".stderr.txt").write_bytes(stderr)
    return code, stdout


def extraction_command(cli, pdf, output_format):
    return [str(cli), "extract-adaptive", "--input", str(pdf), "--format", output_format, "--no-ocr"]


def run(cli, output, split, eval_cli=None, timeout=60):
    freeze_hash = check_freeze()
    metadata = [json.loads(line) for line in (ROOT / "metadata.jsonl").read_text().splitlines()]
    selected = [item for item in metadata if split == "all" or item["reading_order_split"] == split]
    output.mkdir(parents=True, exist_ok=True)
    # Write identity before invoking the first extraction, including a distinct heldout boundary.
    identity = dict(freeze_sha256=freeze_hash, cli=str(cli), cli_sha256=sha(cli), split=split,
                    evaluation_started_after_freeze=True, selected=[item["doc_id"] for item in selected],
                    default_order="legacy", graph_projection_promoted=False,
                    verifier_sha256=sha(Path(__file__)), generator_sha256=sha(ROOT / "generate.py"))
    if eval_cli:
        identity.update(eval_cli=str(eval_cli), eval_cli_sha256=sha(eval_cli))
    (output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    results = []
    for item in selected:
        doc_id = item["doc_id"]
        truth = json.loads((ROOT / "truth" / f"{doc_id}.json").read_text())
        pdf = ROOT / "corpus" / f"{doc_id}.pdf"
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            command = extraction_command(cli, pdf, fmt)
            code, stdout = execute(command, output / f"{doc_id}-{fmt}", timeout)
            try:
                score = score_records(parse_records(stdout), truth, fmt, code)
            except (ValueError, TypeError, KeyError) as error:
                score = dict(verdict="failed", failures=[f"Malformed extraction: {error}"], cli_returncode=code)
            results.append(dict(doc_id=doc_id, format=fmt, command=command, cli_returncode=code, **score))
        if eval_cli:
            command = [str(eval_cli), str(pdf), "--adaptive", "--disable-ocr", "--reading-order-mode", "diagnostic",
                       "--doc-id", doc_id, "--truth-reading-graph", str(ROOT / "graph_truth" / f"{doc_id}.json")]
            code, stdout = execute(command, output / f"{doc_id}-diagnostic", timeout)
            try:
                diagnostic = [json.loads(line) for line in stdout.splitlines() if line.strip()]
                if code != 0 or not diagnostic or not all(isinstance(row, dict) for row in diagnostic):
                    raise ValueError(f"diagnostic CLI failed or returned no scores (exit {code})")
                assessed = score_diagnostic(diagnostic, doc_id)
                results.append(dict(doc_id=doc_id, format="internal-diagnostic", command=command,
                                    cli_returncode=code, **assessed, scores=diagnostic,
                                    scope="page-local graph only; does not qualify emitted or document order"))
            except (ValueError, TypeError) as error:
                results.append(dict(doc_id=doc_id, format="internal-diagnostic", command=command,
                                    cli_returncode=code, verdict="failed", failures=[str(error)]))
    if check_freeze() != freeze_hash:
        raise ValueError("Freeze changed during evaluation; retained raw outputs are unqualified")
    summary = dict(**identity, verdict="failed" if any(r["verdict"] == "failed" for r in results) else "verified",
                   public_checks=sum(r["format"] != "internal-diagnostic" for r in results),
                   failed_public_checks=sum(r["format"] != "internal-diagnostic" and r["verdict"] == "failed" for r in results),
                   failed_diagnostic_checks=sum(r["format"] == "internal-diagnostic" and r["verdict"] == "failed" for r in results),
                   failed_checks=sum(r["verdict"] == "failed" for r in results), results=results,
                   limitations=["Synthetic fixtures; no real-world generalization claim", "Graph metrics retained separately; no graph promotion", "Heldout failures must not be retuned"])
    (output / "report.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--eval-cli", type=Path, help="Optional existing eval runner for separate page-local diagnostics")
    parser.add_argument("--split", choices=("dev", "holdout", "all"), default="dev")
    parser.add_argument("--output", type=Path, required=True, help="Unique ignored evidence directory; existing receipts are not overwritten")
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("Store evaluation evidence outside the frozen experiment pack")
    if output.exists() and any(output.iterdir()):
        parser.error("Evidence directory is not empty; choose a new run directory")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    summary = run(args.cli.resolve(), output, args.split, args.eval_cli.resolve() if args.eval_cli else None, args.timeout)
    print(json.dumps(dict(verdict=summary["verdict"], public_checks=summary["public_checks"], failed_checks=summary["failed_checks"], report=str(output / "report.json"))))
    raise SystemExit(1 if summary["verdict"] == "failed" else 0)


if __name__ == "__main__":
    main()
