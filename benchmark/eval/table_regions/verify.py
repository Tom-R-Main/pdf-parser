#!/usr/bin/env python3
"""Assess frozen development drawings through both bounded public JSONL lanes."""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


REAL_PATH = ROOT.parent / "table_topology_real" / "verify.py"
COMPARE_PATH = ROOT.parent / "table_compare.py"
real = module("table_regions_bounded_runner", REAL_PATH)
compare = module("table_regions_comparator", COMPARE_PATH)
run_command = real.run_command


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def integer(value, minimum=0):
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def public_bbox(value):
    keys = ("x0", "y0", "x1", "y1")
    return (isinstance(value, dict) and all(isinstance(value.get(k), (int,float))
            and not isinstance(value[k], bool) and math.isfinite(value[k]) for k in keys)
            and value["x0"] < value["x1"] and value["y0"] < value["y1"])


def within(inner, outer, tolerance=0):
    return (public_bbox(inner) and public_bbox(outer)
            and inner["x0"] >= outer["x0"]-tolerance and inner["y0"] >= outer["y0"]-tolerance
            and inner["x1"] <= outer["x1"]+tolerance and inner["y1"] <= outer["y1"]+tolerance)


def overlap(a, b):
    return public_bbox(a) and public_bbox(b) and min(a["x1"],b["x1"]) > max(a["x0"],b["x0"]) and min(a["y1"],b["y1"]) > max(a["y0"],b["y0"])


def region_coverage(actual, expected):
    if not public_bbox(actual) or not public_bbox(expected):
        return 0,0
    intersection = max(0,min(actual["x1"],expected["x1"])-max(actual["x0"],expected["x0"])) * max(0,min(actual["y1"],expected["y1"])-max(actual["y0"],expected["y0"]))
    area = lambda b:(b["x1"]-b["x0"])*(b["y1"]-b["y0"])
    return intersection/area(actual),intersection/area(expected)


def extraction_command(binary, pdf, case_id, fmt):
    return [str(binary),"extract-adaptive","--no-ocr","--source-id",case_id,"--input",str(pdf),"--format",fmt]


def load_corpus(root=ROOT):
    freeze = json.loads((root/"freeze.json").read_text())
    for filename,digest in freeze["files_sha256"].items():
        path = Path(filename)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid freeze path")
        if sha(root/path) != digest:
            raise ValueError("frozen drawing drift: "+filename)
    cases = json.loads((root/"cases.json").read_text())
    if len(cases) != 8 or len({c["id"] for c in cases}) != len(cases) or any(c["split"] != "dev" for c in cases):
        raise ValueError("invalid development drawing inventory")
    for case in cases:
        for field in ("pdf","truth"):
            if case[field] not in freeze["files_sha256"]:
                raise ValueError("unfrozen drawing input")
    return cases, freeze


def score(records, truth, case_id, input_sha256, fmt="artifact-jsonl", controls=None):
    controls = controls or dict(region_tolerance_points=6,geometry_tolerance_points=2)
    failures = []
    def check(label, passed):
        if not passed:
            failures.append(label)
    if not isinstance(records,list) or not all(isinstance(r,dict) for r in records):
        return dict(status="failed",failures=["JSONL records are objects"])
    manifests = [r for r in records if r.get("record_type") == "document_manifest"]
    check("manifest first and unique", bool(records) and records[0].get("record_type") == "document_manifest" and len(manifests) == 1)
    manifest = manifests[0] if manifests else {}
    check("manifest page count", integer(manifest.get("page_count"),1) and manifest.get("page_count") == 1)
    document_id = manifest.get("document_id")
    check("document identity", isinstance(document_id,str) and bool(document_id))
    check("manifest input hash", manifest.get("input_sha256") == input_sha256)
    active = completed = ended = False
    for i,record in enumerate(records):
        kind, prov = record.get("record_type"), record.get("provenance")
        label = "record "+str(i)
        check(label+" schema", isinstance(record.get("schema_name"),str) and bool(record["schema_name"])
              and isinstance(record.get("schema_version"),str) and bool(record["schema_version"]) and isinstance(kind,str))
        check(label+" source identity", record.get("source_id") == case_id and record.get("document_id") == document_id
              and isinstance(prov,dict) and prov.get("source_id") == case_id and prov.get("input_sha256") == input_sha256
              and prov.get("document_id") == document_id)
        check(label+" no errors", not record.get("errors") and record.get("status") not in ("failed","partial","cancelled"))
        page = record.get("page_index")
        if page is not None:
            check(label+" page identity", integer(page) and page == 0 and isinstance(prov,dict) and integer(prov.get("page_index")) and prov["page_index"] == 0)
        if fmt == "stream-jsonl":
            check(label+" before document finish", not ended)
            if kind == "page_started":
                check(label+" page start", not active and not completed and page == 0 and record.get("status") == "running")
                active = True
            elif kind == "page_finished":
                check(label+" page finish", active and not completed and page == 0 and record.get("status") == "completed")
                active,completed = False,True
            elif kind == "document_finished":
                check(label+" document finish", completed and not active and record.get("status") == "completed")
                ended = True
            elif page is not None:
                check(label+" active artifact", active and not completed)
        else:
            check(label+" no stream lifecycle", kind not in ("page_started","page_finished","document_finished"))
    if fmt == "stream-jsonl":
        check("complete stream", completed and ended and not active)
    elif fmt != "artifact-jsonl":
        check("known output format",False)
    spans,blocks,tables = {},{},[]
    for record in records:
        kind = record.get("record_type")
        if kind in ("span","block","table"):
            check(kind+" finite object bbox",public_bbox(record.get("bbox")))
            check(kind+" page zero", integer(record.get("page_index")) and record.get("page_index") == 0)
            prov = record.get("provenance")
            check(kind+" provenance geometry",isinstance(prov,dict) and prov.get("bbox") == record.get("bbox"))
        if kind in ("span","block"):
            target = spans if kind == "span" else blocks
            key = record.get("span_id" if kind == "span" else "block_id")
            valid = isinstance(key,str) and bool(key) and key not in target
            check("unique "+kind+" identity",valid)
            check(kind+" literal text",isinstance(record.get("text"),str))
            if valid:
                target[key] = record
        elif kind == "table":
            tables.append(record)
    table_ids = [t.get("table_id") for t in tables]
    reverse_block_spans = {bid:set() for bid in blocks}
    for sid,span in spans.items():
        bid,prov = span.get("reconciled_block_id"),span.get("provenance")
        live = isinstance(bid,str) and bid in blocks
        check("span live reconciled owner",live)
        check("span provenance owner",isinstance(prov,dict) and prov.get("block_ids") == [bid])
        if live:
            reverse_block_spans[bid].add(sid)
            check("span within owning block",within(span.get("bbox"),blocks[bid].get("bbox"),controls["geometry_tolerance_points"]))
    ordered_ids = list(spans)
    for bid,block in blocks.items():
        # writeBlockRecord exposes span_start/span_count plus provenance IDs;
        # it does not expose the table/cell source_span_ids convenience field.
        prov = block.get("provenance")
        ids = prov.get("span_ids") if isinstance(prov,dict) else None
        valid = isinstance(ids,list) and all(isinstance(s,str) and bool(s) for s in ids)
        check("block provenance source IDs",valid)
        if valid:
            check("reciprocal block span membership",len(ids) == len(set(ids)) and set(ids) == reverse_block_spans[bid])
        start,count = block.get("span_start"),block.get("span_count")
        valid_range = integer(start) and integer(count) and start+count <= len(spans)
        check("bounded block span interval",valid_range)
        if valid_range:
            check("block provenance source spans",valid and ids == ordered_ids[start:start+count])
    actual_tokens = Counter(token for record in records if record.get("record_type") == "span"
                            and isinstance(record.get("text"),str) for token in record["text"].split())
    expected_tokens = Counter(token for table in truth["tables"] for row in table["rows"]
                              for cell in row["cells"] for token in cell["text"].split())
    expected_tokens.update(token for prose in truth["retained_prose"] for token in prose["text"].split())
    check("complete source token inventory",actual_tokens == expected_tokens)
    check("unique table identity", all(isinstance(t,str) and bool(t) for t in table_ids) and len(set(t for t in table_ids if isinstance(t,str))) == len(tables))
    check("table count",len(tables) == len(truth["tables"]))
    def order(t):
        bbox=t.get("bbox")
        return (-bbox["y1"],bbox["x0"]) if public_bbox(bbox) else (math.inf,math.inf)
    tables.sort(key=order)
    owned,cell_ids = set(),set()
    for ti,table in enumerate(tables):
        expected = truth["tables"][ti] if ti < len(truth["tables"]) else None
        label = "table "+str(ti)
        rows = table.get("rows")
        valid_rows = isinstance(rows,list) and 0 < len(rows) <= 1000
        check(label+" bounded rows",valid_rows)
        if not valid_rows:
            continue
        check(label+" valid column count",integer(table.get("column_count"),1) and table["column_count"] <= 1000)
        if expected:
            check(label+" bounded expected region",within(table.get("bbox"),expected["region"],controls["region_tolerance_points"]))
            precision,coverage = region_coverage(table.get("bbox"),expected["region"])
            # Independent drawing envelopes include cell padding and section
            # gaps. Tight native text bounds need not equal their edges.
            check(label+" region coverage",precision >= 0.85 and coverage >= 0.45)
            check(label+" row extent",len(rows) == len(expected["rows"]))
            check(label+" column extent",table.get("column_count") == expected["column_count"])
        safe = True
        actual_text = []
        table_owned,table_blocks = set(),set()
        for ri,row in enumerate(rows):
            cells = row.get("cells") if isinstance(row,dict) else None
            valid = isinstance(row,dict) and integer(row.get("row_index")) and row["row_index"] == ri and isinstance(cells,list) and len(cells) <= 1000
            check(label+" physical row "+str(ri),valid)
            if not valid:
                safe = False
                continue
            check(label+" finite row bbox",public_bbox(row.get("bbox")))
            check(label+" bounded row bbox",within(row.get("bbox"),table.get("bbox"),controls["geometry_tolerance_points"]))
            for cell in cells:
                valid = isinstance(cell,dict) and isinstance(cell.get("text"),str)
                check(label+" literal cell",valid)
                if not valid:
                    safe = False
                    continue
                actual_text.append(cell["text"])
                dimensions = all(integer(cell.get(k),1 if k in ("rowspan","colspan") else 0) for k in ("row","column","rowspan","colspan"))
                check(label+" physical cell slots",dimensions and cell.get("row") == ri)
                safe &= dimensions
                if dimensions:
                    check(label+" regular occupancy",cell["rowspan"] == cell["colspan"] == 1)
                cid = cell.get("cell_id")
                valid_id = isinstance(cid,str) and bool(cid) and cid not in cell_ids
                check(label+" unique cell identity",valid_id)
                if valid_id:
                    cell_ids.add(cid)
                prov = cell.get("provenance")
                check(label+" cell schema",cell.get("schema_name") == "table_cell" and cell.get("record_type") == "table_cell"
                      and isinstance(cell.get("schema_version"),str) and bool(cell["schema_version"]))
                check(label+" cell provenance",cell.get("source_id") == case_id and integer(cell.get("page_index")) and cell["page_index"] == 0
                      and isinstance(prov,dict) and prov.get("source_id") == case_id and prov.get("input_sha256") == input_sha256
                      and prov.get("document_id") == document_id and prov.get("page_index") == 0 and prov.get("bbox") == cell.get("bbox"))
                check(label+" finite cell bbox",public_bbox(cell.get("bbox")))
                check(label+" bounded cell bbox",within(cell.get("bbox"),table.get("bbox"),controls["geometry_tolerance_points"]))
                ids,bids = cell.get("source_span_ids"),cell.get("reconciled_block_ids")
                valid_ids = isinstance(ids,list) and all(isinstance(s,str) and bool(s) for s in ids)
                valid_bids = isinstance(bids,list) and all(isinstance(b,str) and bool(b) for b in bids)
                check(label+" cell source IDs",valid_ids and valid_bids)
                if not valid_ids or not valid_bids:
                    continue
                check(label+" provenance span IDs",isinstance(prov,dict) and prov.get("span_ids") == ids)
                check(label+" cell provenance owning blocks",isinstance(prov,dict) and prov.get("block_ids") == bids)
                if not cell["text"].strip():
                    check(label+" blank claims no source",not ids and not bids)
                    continue
                check(label+" nonblank has source",bool(ids))
                check(label+" nonblank cell within physical row",within(cell.get("bbox"),row.get("bbox"),controls["geometry_tolerance_points"]))
                table_owned.update(ids)
                source_text,source_blocks = [],set()
                for sid in ids:
                    check(label+" exclusive source owner",sid not in owned)
                    owned.add(sid)
                    source = spans.get(sid)
                    check(label+" live source reference",source is not None and source.get("page_index") == 0)
                    if source:
                        source_text.append(source["text"] if isinstance(source.get("text"),str) else "")
                        check(label+" source within cell",within(source.get("bbox"),cell.get("bbox"),controls["geometry_tolerance_points"]))
                        check(label+" source within physical row",within(source.get("bbox"),row.get("bbox"),controls["geometry_tolerance_points"]))
                        bid = source.get("reconciled_block_id")
                        check(label+" live source block",isinstance(bid,str) and bid in blocks)
                        if isinstance(bid,str):
                            source_blocks.add(bid)
                check(label+" source literal matches cell"," ".join(source_text).split() == cell["text"].split())
                check(label+" exact owning blocks",set(bids) == source_blocks and len(set(bids)) == len(bids) and all(b in blocks for b in bids))
                table_blocks.update(source_blocks)
        ids,bids,prov = table.get("source_span_ids"),table.get("reconciled_block_ids"),table.get("provenance")
        valid_ids = isinstance(ids,list) and all(isinstance(s,str) and bool(s) for s in ids)
        valid_bids = isinstance(bids,list) and all(isinstance(b,str) and bool(b) for b in bids)
        check(label+" table source IDs",valid_ids and valid_bids)
        if valid_ids:
            check(label+" exact aggregate source spans",len(ids) == len(set(ids)) and set(ids) == table_owned
                  and all(s in spans for s in ids))
            check(label+" table provenance source spans",isinstance(prov,dict) and prov.get("span_ids") == ids)
        if valid_bids:
            check(label+" exact aggregate owning blocks",len(bids) == len(set(bids)) and set(bids) == table_blocks
                  and all(b in blocks for b in bids))
        # Public table provenance keeps the pre-reconciliation layout block
        # interval. Its namespace is separate from reconciled_block_ids.
        layout_start,layout_count = table.get("block_index"),table.get("block_count")
        valid_layout = integer(layout_start) and integer(layout_count,1) and layout_count <= 1000
        check(label+" bounded legacy layout interval",valid_layout)
        if valid_layout:
            legacy_ids = ["block-"+str(i) for i in range(layout_start,layout_start+layout_count)]
            check(label+" table provenance legacy layout blocks",isinstance(prov,dict) and prov.get("block_ids") == legacy_ids)
        if expected:
            check(label+" exact topology",safe and compare.topology_accuracy([table],[expected]) == 1.0)
            expected_text = [c["text"] for r in expected["rows"] for c in r["cells"]]
            check(label+" exact cell text including blank zero dash",actual_text == expected_text)
    for i,left in enumerate(tables):
        for right in tables[i+1:]:
            check("separate table regions",not overlap(left.get("bbox"),right.get("bbox")))
    for prose in truth["retained_prose"]:
        selected = [s for s in spans.values() if within(s.get("bbox"),prose["region"],controls["geometry_tolerance_points"])]
        selected.sort(key=lambda s:(-s["bbox"]["y1"],s["bbox"]["x0"]))
        check("retained prose: "+prose["text"]," ".join(s["text"] if isinstance(s.get("text"),str) else "" for s in selected).split() == prose["text"].split())
        check("prose outside source ownership: "+prose["text"],all(s["span_id"] not in owned for s in selected))
        check("prose outside table regions: "+prose["text"],all(not overlap(s["bbox"],t.get("bbox")) for s in selected for t in tables))
    return dict(status="failed" if failures else "verified",failures=failures,tables=len(tables),cells=len(cell_ids),
                qualification_scope="Independent development drawings; exact regular cells and retained prose; no heldout generalization.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--timeout",type=float,default=30)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 600:
        parser.error("--timeout must be in (0, 600]")
    args.output.mkdir(parents=True,exist_ok=False)
    report = dict(status="failed",results=[],failures=[])
    try:
        cases,freeze = load_corpus()
        binary = args.cli.resolve(strict=True)
        dependencies = [binary,Path(__file__),ROOT/"freeze.json",REAL_PATH,COMPARE_PATH]
        identity = dict(files_sha256={str(p):sha(p) for p in dependencies},
                        head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=REPO,text=True).strip(),
                        controls=freeze["controls"],requested_ocr_mode="--no-ocr",split="dev")
        report["identity"] = identity
        (args.output/"identity.json").write_text(json.dumps(identity,indent=2)+"\n")
        for case in cases:
            pdf = ROOT/case["pdf"]
            before = sha(pdf)
            truth = json.loads((ROOT/case["truth"]).read_text())
            for fmt in ("artifact-jsonl","stream-jsonl"):
                name = case["id"]+"-"+fmt
                command = extraction_command(binary,pdf,case["id"],fmt)
                (args.output/(name+".command.json")).write_text(json.dumps(command,indent=2)+"\n")
                stdout,stderr = args.output/(name+".jsonl"),args.output/(name+".stderr")
                report["active_execution"] = dict(id=case["id"],format=fmt,command=command)
                execution = run_command(command,stdout,stderr,args.timeout)
                result = dict(id=case["id"],format=fmt,command=command,execution=execution)
                try:
                    if execution["stdout_bytes"] > real.MAX_OUTPUT_BYTES:
                        raise ValueError("public output too large to score")
                    records = [json.loads(line) for line in stdout.read_text().splitlines() if line.strip()]
                    result.update(score(records,truth,case["id"],before,fmt,freeze["controls"]))
                except (ValueError,KeyError,TypeError,UnicodeError) as error:
                    result.update(status="failed",failures=["invalid public output: "+str(error)])
                after = sha(pdf)
                result.update(source_sha256_before=before,source_sha256_after=after)
                if execution["failure"] or execution["exit_code"] != 0 or after != before:
                    result["status"] = "failed"
                    result["failures"].extend(x for x in (execution["failure"],"CLI nonzero exit" if execution["exit_code"] else None,
                                             "source changed" if after != before else None) if x)
                report["results"].append(result)
                (args.output/(name+".report.json")).write_text(json.dumps(result,indent=2)+"\n")
                report.pop("active_execution",None)
                if before != after:
                    raise ValueError("stop: source changed")
        load_corpus()
        for filename,digest in identity["files_sha256"].items():
            if sha(Path(filename)) != digest:
                raise ValueError("verification dependency changed: "+filename)
        report["status"] = "verified" if all(r["status"] == "verified" for r in report["results"]) else "failed"
    except KeyboardInterrupt:
        report["interrupted"] = True
        report["failures"].append("interrupted; completed results and raw evidence retained")
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:
        report["failures"].append("operational failure: "+str(error))
    report["verified"] = sum(r["status"] == "verified" for r in report["results"])
    report["total"] = len(report["results"])
    (args.output/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({k:report[k] for k in ("status","verified","total","failures")}))
    return 130 if report.get("interrupted") else int(report["status"] != "verified")


if __name__ == "__main__":
    raise SystemExit(main())
