#!/usr/bin/env python3
"""Drive frozen statement drawings with the existing strict public contract."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SHARED_PATH = ROOT.parent / "table_regions" / "verify.py"
spec = importlib.util.spec_from_file_location("statement_regions_public_contract",SHARED_PATH)
shared = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = shared
spec.loader.exec_module(shared)
sha = shared.sha
run_command,extraction_command = shared.run_command,shared.extraction_command


def load_geometry(root=ROOT):
    freeze = json.loads((root/"geometry-freeze.json").read_text())
    if sha(root/"freeze.json") != freeze["original_freeze_sha256"]:
        raise ValueError("original drawing freeze drift")
    for filename,digest in freeze["files_sha256"].items():
        path = Path(filename)
        if path.is_absolute() or ".." in path.parts or sha(root/path) != digest:
            raise ValueError("frozen row geometry drift: "+filename)
    return json.loads((root/"row_geometry.json").read_text())


def score(records,truth,case_id,input_sha256,fmt="artifact-jsonl",controls=None):
    result = shared.score(records,truth,case_id,input_sha256,fmt,controls)
    geometry = load_geometry()
    selected = [c for c in geometry["cases"] if c["id"] == case_id]
    def check(label,passed):
        if not passed:
            result["failures"].append(label)
    check("frozen row geometry case identity",len(selected) == 1)
    if len(selected) == 1 and isinstance(records,list) and all(isinstance(r,dict) for r in records):
        spans = {r["span_id"]:r for r in records if r.get("record_type") == "span" and isinstance(r.get("span_id"),str)}
        tables = [r for r in records if r.get("record_type") == "table"]
        tables.sort(key=lambda t:(-t["bbox"]["y1"],t["bbox"]["x0"]) if shared.public_bbox(t.get("bbox")) else (math.inf,math.inf))
        frozen_tables = selected[0]["tables"]
        check("frozen row geometry table count",len(tables) == len(frozen_tables))
        for ti,(table,expected) in enumerate(zip(tables,frozen_tables)):
            rows = table.get("rows")
            if not isinstance(rows,list):
                continue
            check("frozen row geometry row count "+str(ti),len(rows) == len(expected["rows"]))
            for ri,(row,frozen_row) in enumerate(zip(rows,expected["rows"])):
                if not isinstance(row,dict) or not isinstance(row.get("cells"),list):
                    continue
                for cell in row["cells"]:
                    if not isinstance(cell,dict) or not isinstance(cell.get("text"),str) or not cell["text"].strip():
                        continue
                    label = "frozen physical row "+str(ti)+"/"+str(ri)
                    tolerance = geometry["controls"]["geometry_tolerance_points"]
                    check(label+" nonblank cell",shared.within(cell.get("bbox"),frozen_row["region"],tolerance))
                    ids = cell.get("source_span_ids")
                    if not isinstance(ids,list):
                        continue
                    for sid in ids:
                        span = spans.get(sid) if isinstance(sid,str) else None
                        check(label+" source",span is not None and shared.within(span.get("bbox"),frozen_row["region"],tolerance))
    if result["failures"]:
        result["status"] = "failed"
    result["geometry_freeze_sha256"] = sha(ROOT/"geometry-freeze.json")
    result["qualification_scope"] = "Independent statement development drawings, including source association with frozen physical rows; no real holdout qualification."
    return result


def load_corpus(root=ROOT):
    freeze = json.loads((root/"freeze.json").read_text())
    for filename,digest in freeze["files_sha256"].items():
        path = Path(filename)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid statement freeze path")
        if sha(root/path) != digest:
            raise ValueError("frozen statement drawing drift: "+filename)
    for filename,digest in freeze["dependencies_sha256"].items():
        path = Path(filename)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid drawing dependency path")
        if sha(root.parent/path) != digest:
            raise ValueError("drawing primitive dependency drift: "+filename)
    cases = json.loads((root/"cases.json").read_text())
    if len(cases) != 8 or len({c["id"] for c in cases}) != len(cases) or any(c["split"] != "dev" for c in cases):
        raise ValueError("invalid statement drawing inventory")
    for case in cases:
        for field in ("pdf","truth"):
            if case[field] not in freeze["files_sha256"]:
                raise ValueError("unfrozen statement input")
    geometry = load_geometry(root)
    if [c["id"] for c in cases] != [c["id"] for c in geometry["cases"]]:
        raise ValueError("geometry/drawing case identity mismatch")
    return cases,freeze


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--timeout",type=float,default=30)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 600:
        parser.error("--timeout must be in (0, 600]")
    args.output.mkdir(parents=True,exist_ok=False)
    report = dict(status="failed",results=[],failures=[],
                  qualification_scope="Independent statement development drawings; no real holdout, merged-cell or continuation qualification.")
    try:
        cases,freeze = load_corpus()
        binary = args.cli.resolve(strict=True)
        dependencies = [binary,Path(__file__),ROOT/"freeze.json",ROOT/"geometry-freeze.json",ROOT/"row_geometry.json",
                        SHARED_PATH,shared.REAL_PATH,shared.COMPARE_PATH]
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
                    if execution["stdout_bytes"] > shared.real.MAX_OUTPUT_BYTES:
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
