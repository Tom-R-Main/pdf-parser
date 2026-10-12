#!/usr/bin/env python3
"""Deterministic topology controls; truth comes from drawing specifications."""
import hashlib
import json
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def pdf(content, extra=""):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " + extra +
                " /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>").encode(),
               b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    output = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(output)


def text(value, x, y):
    value = value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    return f"BT /F1 12 Tf 1 0 0 1 {x} {y} Tm ({value}) Tj ET"


def cases():
    for split, left, top, width, prefix in [("dev", 60, 720, 160, "D"),
                                            ("holdout", 95, 680, 135, "H")]:
        xs = [left, left+width, left+2*width]
        ys = [top, top-40, top-80, top-120]
        rules = [f"{x} {ys[-1]} m {x} {top} l S" for x in xs]
        rules += [f"{left} {y} m {xs[-1]} {y} l S" for y in ys]
        values = [[prefix+" Account", prefix+" Amount"], [prefix+" Cash", "0"],
                  [prefix+" Debt", "(275)" if split == "dev" else "(640)"]]
        for family in ("blank-zero", "reverse-multispan", "boundary-ownership"):
            commands = ["0.5 w", *rules]
            rows = []
            for row_index, row in enumerate(values):
                cells = []
                for column, value in enumerate(row):
                    if family == "blank-zero" and row_index == 2 and column == 1:
                        value = ""
                    y = ys[row_index]-22
                    if family == "boundary-ownership" and row_index == 1 and column == 0:
                        # This text crosses a row rule. Its center belongs to one
                        # band; tolerant inclusion must never duplicate it.
                        y = ys[row_index]-4
                    if value:
                        commands.append(text(value, xs[column]+8, y))
                    cells.append({"text":value, "row":row_index, "column":column,
                                  "rowspan":1, "colspan":1})
                rows.append({"row_index":row_index, "cells":cells})
            if family == "reverse-multispan":
                # Independently positioned tokens on the same line, deliberately
                # emitted right-to-left in content-stream order.
                commands = ["0.5 w", *rules]
                for row_index in reversed(range(3)):
                    for column in reversed(range(2)):
                        value = rows[row_index]["cells"][column]["text"]
                        if column == 0:
                            first, second = value.split(" ")
                            commands += [text(second, xs[column]+24, ys[row_index]-22),
                                         text(first, xs[column]+8, ys[row_index]-22)]
                        else:
                            commands.append(text(value, xs[column]+8, ys[row_index]-22))
            truth = [{"column_count":2, "rows":rows, "topology_required":True,
                      "source_ownership_required":True}]
            # Boundary ownership is an invariant control, not an arbitrary
            # semantic interpretation of lettering crossing a rule.
            yield f"{family}-{split}", split, pdf(("\n".join(commands)+"\n").encode()), truth, family
        # Graphic axes with narrative prose provide a no-table control.
        content = "\n".join(["0.5 w", f"{left} 400 m {left} 500 l S",
                              f"{left} 400 m {left+200} 400 l S",
                              text(prefix+" Narrative only", left, 620),
                              text(prefix+" No numeric columns", left, 590)])+"\n"
        yield f"graphic-axis-{split}", split, pdf(content.encode()), [], "negative"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    def retain(path, data):
        if path.exists():
            if path.read_bytes() != data:raise ValueError("frozen artifact differs: "+str(path))
        elif args.check:
            raise ValueError("frozen artifact missing: "+str(path))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    manifest, hashes = [], {}
    for name, split, data, truth, family in cases():
        path = ROOT / "corpus" / (name+".pdf")
        retain(path, data)
        truth_path = ROOT / "truth" / (name+".json")
        retain(truth_path, (json.dumps(truth, indent=2)+"\n").encode())
        hashes[str(path.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
        hashes[str(truth_path.relative_to(ROOT))] = hashlib.sha256(truth_path.read_bytes()).hexdigest()
        manifest.append({"id":name,"split":split,"pdf":str(path.relative_to(ROOT)),
                         "truth":str(truth_path.relative_to(ROOT)),"family":family})
    retain(ROOT/"cases.json", (json.dumps(manifest, indent=2)+"\n").encode())
    hashes["cases.json"] = hashlib.sha256((ROOT/"cases.json").read_bytes()).hexdigest()
    freeze = {"version":1,"files_sha256":hashes,
              "acceptance":{"required":["one source span owner per semantic cell assignment",
                  "blank is distinct from zero","exact cell coordinates and spans on regular grids",
                  "reverse content streams retain visual cell text order","no table on graphic-axis controls"],
                  "boundary_case":"retain every input label exactly once; crossing lettering has no row-truth claim"},
              "scope":"Small synthetic reductions. Holdouts assessed after development; no rule tuning on holdout results."}
    retain(ROOT/"freeze.json", (json.dumps(freeze, indent=2)+"\n").encode())


if __name__ == "__main__":
    main()
