#!/usr/bin/env python3
"""Qualify frozen real-document regions, selected rows, and continuation links."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
DEFAULT_SOURCE_ROOT = ROOT.parent / "raw_cache" / "table_topology_real"
MAX_OUTPUT_BYTES = 128 * 1024 * 1024
sys.path.insert(0, str(ROOT.parent))
from table_compare import table_topology


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def integer(value, minimum=0, maximum=1000):
    return type(value) is int and minimum <= value <= maximum


def tokens(value):
    if not isinstance(value, str):
        raise ValueError("text must be a string")
    return value.split()


def coordinates(value):
    """Truth uses lists; public JSON boxes use x0/y0/x1/y1 objects."""
    if isinstance(value, dict) and all(key in value for key in ("x0", "y0", "x1", "y1")):
        value = [value[key] for key in ("x0", "y0", "x1", "y1")]
    if (isinstance(value, list) and len(value) == 4
            and all(type(v) in (int, float) and math.isfinite(v) for v in value)
            and value[2] > value[0] and value[3] > value[1]):
        return value
    return None


def bbox(value):
    return coordinates(value) is not None


def public_bbox(value):
    return isinstance(value, dict) and bbox(value)


def coverage(region, candidate):
    region, candidate = coordinates(region), coordinates(candidate)
    if region is None or candidate is None:
        return (0.0, 0.0)
    area = max(0, min(region[2], candidate[2]) - max(region[0], candidate[0])) * max(
        0, min(region[3], candidate[3]) - max(region[1], candidate[1]))
    return (area / ((region[2] - region[0]) * (region[3] - region[1])),
            area / ((candidate[2] - candidate[0]) * (candidate[3] - candidate[1])))


def basename(value):
    return isinstance(value, str) and value not in ("", ".", "..") and Path(value).name == value and "/" not in value and "\\" not in value


def load_corpus(root=ROOT):
    root = Path(root)
    freeze = json.loads((root / "freeze.json").read_text())
    bindings = freeze["files_sha256"]
    if not isinstance(bindings, dict) or not {"sources.json", "cases.json"} <= bindings.keys():
        raise ValueError("freeze must bind sources.json and cases.json")
    for name, digest in bindings.items():
        if not basename(name) or sha(root / name) != digest:
            raise ValueError("frozen corpus drift: " + str(name))
    controls = freeze["controls"]
    for key in ("min_region_coverage", "min_table_coverage"):
        if type(controls.get(key)) not in (int, float) or controls[key] != 0.7:
            raise ValueError("unsupported frozen selector: " + key)
    sources = json.loads((root / "sources.json").read_text())
    cases = json.loads((root / "cases.json").read_text())
    if not isinstance(sources, list) or not 0 < len(sources) <= 3 or not isinstance(cases, list) or not 0 < len(cases) <= 20:
        raise ValueError("empty or malformed corpus")
    source_ids = set()
    for source in sources:
        if not isinstance(source, dict) or not basename(source.get("id")) or source["id"] in source_ids:
            raise ValueError("duplicate or invalid source id")
        source_ids.add(source["id"])
        if not basename(source.get("filename")) or not integer(source.get("page_count"), 1, 7):
            raise ValueError("invalid source filename or page count")
        if any(not isinstance(source.get(key), str) or not source[key] for key in ("issuer", "template_family")):
            raise ValueError("missing issuer/template identity")
        digest = source.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("invalid source SHA256")
    by_source = {source["id"]: source for source in sources}
    case_ids = set()
    families = {"dev": set(), "holdout": set()}
    issuers = {"dev": set(), "holdout": set()}
    for case in cases:
        if not isinstance(case, dict) or not basename(case.get("id")) or case["id"] in case_ids:
            raise ValueError("duplicate or invalid case id")
        case_ids.add(case["id"])
        source = by_source.get(case.get("source_id"))
        if source is None or case.get("split") not in families:
            raise ValueError("unknown source or split")
        families[case["split"]].add(source["template_family"])
        issuers[case["split"]].add(source["issuer"])
        pages = case.get("pages")
        if (not isinstance(pages, list) or len(pages) != 2
                or not all(integer(p, 1, source["page_count"]) for p in pages)
                or pages[0] > pages[1]):
            raise ValueError("invalid original page selection")
        tables = case.get("tables")
        if not isinstance(tables, list) or not tables or len(tables) > 100:
            raise ValueError("invalid selected tables")
        keys = set()
        for table in tables:
            if not isinstance(table, dict) or not basename(table.get("id")) or table["id"] in keys:
                raise ValueError("duplicate or invalid table key")
            keys.add(table["id"])
            if not integer(table.get("page_index"), pages[0] - 1, pages[1] - 1) or not bbox(table.get("bbox")):
                raise ValueError("invalid table page or frozen region")
            if "column_count" in table and not integer(table["column_count"], 1):
                raise ValueError("invalid truth column count")
            for row in table.get("rows", []):
                if (not isinstance(row, dict) or not tokens(row.get("tokens"))
                        or type(row.get("prefix", False)) is not bool
                        or not integer(row.get("occurrences", 1), 1)):
                    raise ValueError("invalid row assertion")
            for header in table.get("headers", []):
                if (not isinstance(header, dict) or not tokens(header.get("text"))
                        or not integer(header.get("row")) or not integer(header.get("column"))
                        or not integer(header.get("rowspan"), 1) or not integer(header.get("colspan"), 1)):
                    raise ValueError("invalid physical header assertion")
        for relation in case.get("relations", []):
            if (not isinstance(relation, dict) or relation.get("from") not in keys
                    or relation.get("to") not in keys or relation["from"] == relation["to"]
                    or type(relation.get("continues")) is not bool):
                raise ValueError("invalid continuation assertion")
    if families["dev"] & families["holdout"] or issuers["dev"] & issuers["holdout"]:
        raise ValueError("issuer/template family crosses frozen splits")
    return sources, cases, freeze


def extraction_command(binary, pdf, case, output_format):
    first, last = case["pages"]
    return [str(binary), "extract-adaptive", "--no-ocr", "--input", str(pdf),
            "--pages", f"{first}-{last}", "--source-id", case["id"], "--format", output_format]


def score(records, case, source, output_format="artifact-jsonl", controls=None):
    controls = controls or {"min_region_coverage": 0.7, "min_table_coverage": 0.7}
    checks = []

    def check(name, passed, **details):
        checks.append(dict(check=name, passed=bool(passed), **details))

    if not isinstance(records, list) or not all(isinstance(r, dict) for r in records):
        check("JSONL records are objects", False)
        return finish(checks, {})
    selected_pages = list(range(case["pages"][0] - 1, case["pages"][1]))
    manifests = [r for r in records if r.get("record_type") == "document_manifest"]
    check("manifest first and unique", bool(records) and records[0].get("record_type") == "document_manifest" and len(manifests) == 1)
    manifest = manifests[0] if manifests else {}
    check("original document page count", integer(manifest.get("page_count"), 1) and manifest.get("page_count") == source["page_count"])
    check("whole-file input SHA256", manifest.get("input_sha256") == source["sha256"])
    check("caller source identity", manifest.get("source_id") == case["id"])
    document_id = manifest.get("document_id")
    check("document identity present", isinstance(document_id, str) and bool(document_id))
    active = None
    completed = []
    ended = False
    for index, record in enumerate(records):
        kind = record.get("record_type")
        label = f"record {index} {kind}"
        check(label + " schema envelope", isinstance(record.get("schema_name"), str) and bool(record["schema_name"])
              and isinstance(record.get("schema_version"), str) and bool(record["schema_version"]) and isinstance(kind, str))
        provenance = record.get("provenance")
        check(label + " source identity", record.get("source_id") == case["id"] and record.get("document_id") == document_id
              and isinstance(provenance, dict) and provenance.get("source_id") == case["id"]
              and provenance.get("input_sha256") == source["sha256"] and provenance.get("document_id") == document_id)
        check(label + " no errors", not record.get("errors") and record.get("status") not in ("failed", "partial", "cancelled"))
        page = record.get("page_index")
        if page is not None:
            check(label + " original selected page", integer(page) and page in selected_pages)
            check(label + " provenance page", isinstance(provenance, dict) and integer(provenance.get("page_index")) and provenance["page_index"] == page)
        if output_format == "stream-jsonl":
            check(label + " before document completion", not ended)
            if kind == "page_started":
                expected = selected_pages[len(completed)] if len(completed) < len(selected_pages) else None
                check(label + " page start", active is None and page == expected and record.get("status") == "running")
                active = page
            elif kind == "page_finished":
                check(label + " page finish", active is not None and page == active and record.get("status") == "completed")
                completed.append(page)
                active = None
            elif kind == "document_finished":
                check(label + " document finish", active is None and completed == selected_pages and record.get("status") == "completed")
                ended = True
            elif page is not None:
                check(label + " active page artifact", active is not None and page == active)
        else:
            check(label + " batch lifecycle", kind not in ("page_started", "page_finished", "document_finished"))
    if output_format == "stream-jsonl":
        check("complete selected-page stream", ended and active is None and completed == selected_pages)
    spans = {}
    tables = []
    table_ids = set()
    cell_ids = set()
    owned = set()
    for record in records:
        if record.get("record_type") == "span":
            sid = record.get("span_id")
            check("span original selected page and literal text", integer(record.get("page_index"))
                  and record["page_index"] in selected_pages and isinstance(record.get("text"), str), span_id=sid)
            valid = isinstance(sid, str) and bool(sid) and sid not in spans
            check("unique global span identity", valid, span_id=sid)
            if valid:
                spans[sid] = record
    for table in (r for r in records if r.get("record_type") == "table"):
        tid = table.get("table_id")
        valid_id = isinstance(tid, str) and bool(tid) and tid not in table_ids
        check("unique global table identity", valid_id, table_id=tid)
        if valid_id:
            table_ids.add(tid)
        tables.append(table)
        check(f"{tid} table bounds", public_bbox(table.get("bbox")))
        check(f"{tid} numeric column extent", integer(table.get("column_count"), 1))
        check(f"{tid} logical identity and part", isinstance(table.get("logical_table_id"), str) and bool(table["logical_table_id"])
              and integer(table.get("table_part_index")))
        for field in ("continued_from_table_id", "continued_to_table_id"):
            check(f"{tid} {field} type", field in table and (table[field] is None or (isinstance(table[field], str) and bool(table[field]))))
        rows = table.get("rows")
        well_formed = isinstance(rows, list) and bool(rows) and len(rows) <= 1000
        check(f"{tid} bounded rows", well_formed)
        if not well_formed:
            continue
        safe_topology = True
        for ri, row in enumerate(rows):
            cells = row.get("cells") if isinstance(row, dict) else None
            valid_row = isinstance(row, dict) and integer(row.get("row_index")) and row["row_index"] == ri and isinstance(cells, list) and len(cells) <= 1000
            check(f"{tid} row {ri} physical extent", valid_row)
            if not valid_row:
                safe_topology = False
                continue
            for ci, cell in enumerate(cells):
                label = f"{tid} cell {ri}/{ci}"
                valid_cell = isinstance(cell, dict) and isinstance(cell.get("text"), str)
                check(label + " literal text", valid_cell)
                if not valid_cell:
                    safe_topology = False
                    continue
                check(label + " schema envelope", cell.get("schema_name") == "table_cell" and cell.get("record_type") == "table_cell"
                      and isinstance(cell.get("schema_version"), str) and bool(cell["schema_version"]))
                dimensions = all(integer(cell.get(k), 1 if k in ("rowspan", "colspan") else 0) for k in ("row", "column", "rowspan", "colspan"))
                check(label + " numeric physical slots", dimensions and cell.get("row") == ri)
                extents = (dimensions and integer(table.get("column_count"), 1)
                           and cell["row"] + cell["rowspan"] <= len(rows)
                           and cell["column"] + cell["colspan"] <= table["column_count"])
                check(label + " physical slots within table", extents)
                safe_topology &= extents
                cid = cell.get("cell_id")
                valid_id = isinstance(cid, str) and bool(cid) and cid not in cell_ids
                check(label + " unique cell identity", valid_id)
                if valid_id:
                    cell_ids.add(cid)
                prov = cell.get("provenance")
                check(label + " page and source identity", integer(cell.get("page_index")) and cell.get("page_index") == table.get("page_index")
                      and cell.get("source_id") == case["id"] and isinstance(prov, dict)
                      and prov.get("source_id") == case["id"] and prov.get("input_sha256") == source["sha256"]
                      and prov.get("document_id") == document_id and integer(prov.get("page_index")) and prov["page_index"] == table.get("page_index"))
                ids = cell.get("source_span_ids")
                valid_links = isinstance(ids, list) and all(isinstance(s, str) and bool(s) for s in ids) and len(set(ids)) == len(ids)
                check(label + " span link shape", valid_links)
                if not valid_links:
                    continue
                check(label + " provenance span links", isinstance(prov, dict) and prov.get("span_ids") == ids)
                if not cell["text"].strip():
                    check(label + " blank owns no text", not ids)
                    check(label + " blank owns no blocks", cell.get("reconciled_block_ids") == [])
                else:
                    check(label + " nonblank has source text", bool(ids))
                source_text = []
                for sid in ids:
                    span = spans.get(sid)
                    same_page = span is not None and span.get("page_index") == table.get("page_index") and span.get("source_id") == case["id"] and isinstance(span.get("text"), str)
                    check(label + " nondangling page-local span", same_page, span_id=sid)
                    check(label + " exclusive span ownership", sid not in owned, span_id=sid)
                    owned.add(sid)
                    if same_page:
                        source_text.append(span["text"])
                check(label + " literal source text agreement", " ".join(source_text).split() == cell["text"].split())
        check(f"{tid} bounded physical topology", safe_topology and table_topology(table) is not None)
        table_links = table.get("source_span_ids")
        check(f"{tid} table source links", isinstance(table_links, list) and all(isinstance(sid, str) and sid in spans
              and spans[sid].get("page_index") == table.get("page_index") for sid in table_links))
    selected = {}
    for truth in case["tables"]:
        candidates = []
        for table in tables:
            if not public_bbox(table.get("bbox")):
                continue
            overlap_region, overlap_table = coverage(truth["bbox"], table.get("bbox"))
            if (table.get("page_index") == truth["page_index"] and overlap_region >= controls["min_region_coverage"]
                    and overlap_table >= controls["min_table_coverage"]):
                candidates.append(table)
        key = truth["id"]
        check(key + " exactly one frozen-region candidate", len(candidates) == 1, candidate_ids=[t.get("table_id") for t in candidates])
        if len(candidates) != 1:
            continue
        table = candidates[0]
        selected[key] = table
        if "column_count" in truth:
            check(key + " selected column extent", type(table.get("column_count")) is int and table["column_count"] == truth["column_count"])
        valid_rows = table.get("rows", [])
        valid_rows = valid_rows if isinstance(valid_rows, list) else []
        row_tokens = []
        cells = []
        for row in valid_rows:
            row_cells = row.get("cells", []) if isinstance(row, dict) else []
            if not isinstance(row_cells, list) or not all(isinstance(c, dict) and isinstance(c.get("text"), str) and integer(c.get("column")) for c in row_cells):
                continue
            row_cells = sorted(row_cells, key=lambda c: c["column"])
            cells.extend(row_cells)
            row_tokens.append(" ".join(c["text"] for c in row_cells).split())
        for assertion in truth.get("rows", []):
            expected = tokens(assertion["tokens"])
            matches = sum((actual[:len(expected)] == expected if assertion.get("prefix", False) else actual == expected) for actual in row_tokens)
            check(key + " literal selected row", matches == assertion.get("occurrences", 1), tokens=assertion["tokens"], matches=matches)
        for header in truth.get("headers", []):
            matches = [c for c in cells if c["text"].split() == tokens(header["text"])
                       and all(type(c.get(k)) is int and c[k] == header[k] for k in ("row", "column", "rowspan", "colspan"))]
            check(key + " physical merged header", len(matches) == 1, header=header, matches=len(matches))
    for relation in case.get("relations", []):
        label = f"relation {relation['from']} -> {relation['to']}"
        left, right = selected.get(relation["from"]), selected.get(relation["to"])
        present = left is not None and right is not None
        check(label + " both selected tables present", present)
        if not present:
            continue
        distinct = left.get("table_id") != right.get("table_id")
        check(label + " distinct physical tables", distinct)
        if relation["continues"]:
            check(label + " reciprocal continuation", distinct and left.get("continued_to_table_id") == right.get("table_id")
                  and right.get("continued_from_table_id") == left.get("table_id"))
            check(label + " logical identity and consecutive parts", isinstance(left.get("logical_table_id"), str)
                  and bool(left["logical_table_id"]) and left.get("logical_table_id") == right.get("logical_table_id")
                  and integer(left.get("table_part_index")) and integer(right.get("table_part_index"))
                  and right["table_part_index"] == left["table_part_index"] + 1)
        else:
            check(label + " separate logical identity", distinct and isinstance(left.get("logical_table_id"), str)
                  and isinstance(right.get("logical_table_id"), str) and left["logical_table_id"] != right["logical_table_id"])
            check(label + " no cross continuation links", all(left.get(field) != right.get("table_id") and right.get(field) != left.get("table_id")
                  for field in ("continued_from_table_id", "continued_to_table_id")))
    return finish(checks, {key: table.get("table_id") for key, table in selected.items()})


def finish(checks, selected):
    failures = [c["check"] for c in checks if not c["passed"]]
    return dict(status="failed" if failures else "verified", failures=failures, checks=checks, selected_tables=selected,
                qualification_scope="frozen regions, selected literal rows and headers, continuation links; not full-table accuracy")


def signal_owned_group(process, signum):
    """Signal only the group created by this invocation's new session."""
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin can deny signalling a group containing only unreaped zombies.
        # An active member's denial must remain an operational failure.
        states = subprocess.run(["ps", "-ax", "-o", "pgid=,stat="], capture_output=True, text=True, check=True).stdout.splitlines()
        for row in states:
            fields = row.split()
            if len(fields) == 2 and fields[0] == str(process.pid) and not fields[1].startswith("Z"):
                raise


def finalize_owned_group(process, grace_seconds=0.2):
    """Kill remaining descendants before reaping the identity-bearing leader."""
    try:
        signal_owned_group(process, signal.SIGTERM)
        time.sleep(grace_seconds)
    finally:
        # Always send KILL, even when TERM already ended the leader, or when
        # an exception/interrupt arrived during the grace period.
        try:
            signal_owned_group(process, signal.SIGKILL)
        finally:
            process.wait(timeout=5)


def run_command(command, stdout_path, stderr_path, timeout):
    started = time.monotonic()
    reason = None
    if not all(hasattr(os, name) for name in ("waitid", "WNOWAIT", "WEXITED", "WNOHANG", "P_PID")):
        raise OSError("owner-safe process-group finalization requires waitid/WNOWAIT")
    with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            while True:
                if time.monotonic() - started >= timeout:
                    reason = "CLI timeout"
                elif stdout_path.stat().st_size + stderr_path.stat().st_size > MAX_OUTPUT_BYTES:
                    reason = "CLI output budget exceeded"
                if reason:
                    break
                # Observe completion without reaping. Retaining the leader
                # reserves its PID/PGID until group finalization has finished.
                if os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
                    break
                time.sleep(0.05)
        finally:
            finalize_owned_group(process)
    if stdout_path.stat().st_size + stderr_path.stat().st_size > MAX_OUTPUT_BYTES:
        reason = "CLI output budget exceeded"
    return dict(exit_code=process.returncode, failure=reason, owned_process_group=process.pid,
                group_finalization="TERM, bounded grace, KILL, leader reaped last", elapsed_seconds=time.monotonic() - started,
                stdout_bytes=stdout_path.stat().st_size, stderr_bytes=stderr_path.stat().st_size,
                output_budget_bytes=MAX_OUTPUT_BYTES, output_budget_enforcement="sampled, 50 ms; overshoot possible")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--split", choices=("dev", "holdout", "all"), required=True)
    parser.add_argument("--source-root", type=Path, default=DEFAULT_SOURCE_ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 600:
        parser.error("--timeout must be in (0, 600]")
    args.output.mkdir(parents=True, exist_ok=False)
    report = dict(status="failed", results=[], failures=[], qualification_scope="partial selected-region truth, not full-table accuracy")
    try:
        sources, cases, freeze = load_corpus()
        binary = args.cli.resolve(strict=True)
        identity = dict(cli=str(binary), cli_sha256=sha(binary), verifier_sha256=sha(Path(__file__)),
                        comparator_sha256=sha(ROOT.parent / "table_compare.py"), freeze_sha256=sha(ROOT / "freeze.json"),
                        head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                        split=args.split, controls=freeze["controls"], requested_ocr_mode="--no-ocr")
        report["identity"] = identity
        (args.output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
        by_source = {s["id"]: s for s in sources}
        selected_cases = [c for c in cases if args.split == "all" or c["split"] == args.split]
        if not selected_cases:
            raise ValueError("selected split has no cases")
        for case in selected_cases:
            source = by_source[case["source_id"]]
            pdf = args.source_root / source["filename"]
            before = sha(pdf)
            if before != source["sha256"]:
                raise ValueError("wrong whole-file input hash: " + source["id"])
            for fmt in ("artifact-jsonl", "stream-jsonl"):
                name = case["id"] + "-" + fmt
                command = extraction_command(binary, pdf, case, fmt)
                (args.output / (name + ".command.json")).write_text(json.dumps(command, indent=2) + "\n")
                stdout_path = args.output / (name + ".jsonl")
                report["active_execution"] = dict(id=case["id"], format=fmt, command=command,
                                                 stdout=str(stdout_path), stderr=str(args.output / (name + ".stderr")))
                execution = run_command(command, stdout_path, args.output / (name + ".stderr"), args.timeout)
                result = dict(id=case["id"], format=fmt, command=command, execution=execution)
                try:
                    if execution["stdout_bytes"] > MAX_OUTPUT_BYTES:
                        raise ValueError("output too large to score")
                    records = [json.loads(line) for line in stdout_path.read_text().splitlines() if line.strip()]
                    result.update(score(records, case, source, fmt, freeze["controls"]))
                except (ValueError, KeyError, TypeError, UnicodeError) as error:
                    result.update(status="failed", failures=["invalid public output: " + str(error)], checks=[])
                after = sha(pdf)
                result["source_sha256_before"] = before
                result["source_sha256_after"] = after
                if execution["failure"] or execution["exit_code"] != 0 or after != before:
                    result["status"] = "failed"
                    result["failures"].extend(x for x in (execution["failure"], "CLI nonzero exit" if execution["exit_code"] != 0 else None,
                                                        "source changed during verification" if after != before else None) if x)
                report["results"].append(result)
                (args.output / (name + ".report.json")).write_text(json.dumps(result, indent=2) + "\n")
                report.pop("active_execution", None)
                if after != before:
                    raise ValueError("stop: source changed")
        load_corpus()
        for path, digest in ((binary, identity["cli_sha256"]), (Path(__file__), identity["verifier_sha256"]),
                             (ROOT.parent / "table_compare.py", identity["comparator_sha256"]), (ROOT / "freeze.json", identity["freeze_sha256"])):
            if sha(path) != digest:
                raise ValueError("verification identity changed: " + str(path))
        report["status"] = "verified" if all(r["status"] == "verified" for r in report["results"]) else "failed"
    except KeyboardInterrupt:
        report["status"] = "failed"
        report["interrupted"] = True
        report["failures"].append("verification interrupted; completed results and raw evidence retained")
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report["failures"].append("operational failure: " + str(error))
    report["verified"] = sum(r["status"] == "verified" for r in report["results"])
    report["total"] = len(report["results"])
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: report[k] for k in ("status", "verified", "total", "failures")}))
    return 130 if report.get("interrupted") else int(report["status"] != "verified")


if __name__ == "__main__":
    raise SystemExit(main())
