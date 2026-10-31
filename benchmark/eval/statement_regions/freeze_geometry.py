#!/usr/bin/env python3
"""Freeze supplemental physical rows from the original drawing specifications."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("statement_geometry_drawings",ROOT/"generate.py")
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)


def contract():
    original = generate.table
    def capture(commands,matrix,ys,**options):
        value = original(commands,matrix,ys,**options)
        value["drawing_row_regions"] = [dict(row_index=i,region=dict(x0=value["region"]["x0"],
                            y0=ys[i+1],x1=value["region"]["x1"],y1=ys[i])) for i in range(len(matrix))]
        return value
    generate.table = capture
    try:
        cases = [dict(id=name,tables=[dict(rows=t["drawing_row_regions"]) for t in truth["tables"]])
                 for name,pdf,truth in generate.cases()]
    finally:
        generate.table = original
    return dict(version=1,cases=cases,controls=dict(geometry_tolerance_points=2),
                scope="Supplemental row envelopes derived solely from frozen pre-assessment drawing coordinates; no native whitespace-edge equality claim.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    args = parser.parse_args()
    def retain(path,data):
        if path.exists():
            if path.read_bytes() != data:
                raise ValueError("frozen row geometry differs: "+str(path))
        elif args.check:
            raise ValueError("frozen row geometry missing: "+str(path))
        else:
            path.write_bytes(data)
    encoded = lambda value:(json.dumps(value,indent=2)+"\n").encode()
    data = encoded(contract())
    retain(ROOT/"row_geometry.json",data)
    freeze = dict(version=1,original_freeze_sha256=hashlib.sha256((ROOT/"freeze.json").read_bytes()).hexdigest(),
                  files_sha256={"row_geometry.json":hashlib.sha256(data).hexdigest(),
                                "freeze_geometry.py":hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                "generate.py":hashlib.sha256((ROOT/"generate.py").read_bytes()).hexdigest()})
    data = encoded(freeze)
    retain(ROOT/"geometry-freeze.json",data)
    print(json.dumps(dict(geometry_freeze_sha256=hashlib.sha256(data).hexdigest(),original_freeze_sha256=freeze["original_freeze_sha256"])))


if __name__ == "__main__":
    main()
