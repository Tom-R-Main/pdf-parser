#!/usr/bin/env python3
"""Freeze independent section-label and wrapped-row development drawings."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DRAWING_PATH = ROOT.parent / "table_regions" / "generate.py"
spec = importlib.util.spec_from_file_location("statement_drawing_primitives",DRAWING_PATH)
drawing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drawing)


def table(commands,matrix,ys,wrapped=None,numeric_baselines=None,indents=None):
    xs = [60,330,440,550]
    wrapped,numeric_baselines,indents = wrapped or {},numeric_baselines or {},indents or {}
    rows = []
    for ri,values in enumerate(matrix):
        cells = []
        for ci,value in enumerate(values):
            if value:
                if (ri,ci) in wrapped:
                    for part,x,y in wrapped[(ri,ci)]:
                        commands.append(drawing.text(part,x,y))
                else:
                    x = indents.get(ri,68) if ci == 0 else [426,536][ci-1]-len(value)*6
                    y = numeric_baselines.get(ri,ys[ri]-22) if ci else ys[ri]-22
                    commands.append(drawing.text(value,x,y))
            cells.append(dict(text=value,row=ri,column=ci,rowspan=1,colspan=1))
        rows.append(dict(row_index=ri,cells=cells))
    return dict(column_count=3,rows=rows,topology_required=True,source_ownership_required=True,
                region=drawing.box([xs[0],ys[-1],xs[-1],ys[0]]))


def cases():
    commands = ["0.5 w"]
    sections = table(commands,[["Item","Now","Prior"],["SUPPLIES","",""],["Paper","12","10"],
                     ["Ink","0",""],["TOOLS","",""],["Brushes","4","3"],["Total","16","13"]],
                     [710,674,638,602,566,530,494,450])
    yield drawing.case("statement-section-labels-v1",commands,[sections],
                       [dict(text="Workshop stock statement",x=140,y=750)],
                       "Section labels occupy the label column; their numeric cells remain blank within one complete statement.")

    commands = ["0.5 w"]
    before = table(commands,[["Item","Ordered","Arrived"],["Replacement filter kits","12","12"],
                   ["Hose","7","6"],["Valve","0","-"],["Total","19","18"]],
                   [710,668,592,550,508,466],
                   wrapped={(1,0):[("Replacement",68,652),("filter kits",68,636)]},numeric_baselines={1:618})
    yield drawing.case("wrapped-label-before-values-v1",commands,[before],
                       [dict(text="Maintenance delivery statement",x=116,y=750)],
                       "Two positioned label fragments precede the numeric baseline but belong to one tall physical row.")

    commands = ["0.5 w"]
    after = table(commands,[["Item","Issued","Returned"],["Portable sample carriers","23","21"],
                  ["Glass trays","0","3"],["Total","23","24"]],
                  [710,668,588,546,504],
                  wrapped={(1,0):[("Portable sample",68,622),("carriers",68,606)]},numeric_baselines={1:646})
    yield drawing.case("wrapped-label-after-values-v1",commands,[after],
                       [dict(text="Laboratory checkout statement",x=122,y=750)],
                       "A numeric baseline precedes both label fragments inside the same physical row.")

    commands = ["0.5 w"]
    hierarchy = table(commands,[["Item","Open","Closed"],["OPERATIONS","",""],["Storage","8","7"],
                      ["Cold area","2","0"],["Dry area","6","7"],["Subtotal","8","7"],
                      ["OTHER","",""],["Repairs","-",""],["Grand total","8","7"]],
                      [730,692,654,616,578,540,502,464,426,388],indents={3:88,4:88})
    for y in (506,392,394):
        commands += [drawing.rule(340,y,426,y),drawing.rule(450,y,536,y)]
    yield drawing.case("indented-hierarchy-sparse-subtotal-v1",commands,[hierarchy],
                       [dict(text="Facilities activity statement",x=122,y=764)],
                       "Indented detail rows, internal section labels, short subtotal rules and sparse dash/blank amounts retain one grid.")

    commands = ["0.5 w"]
    first = table(commands,[["Lot","Due","Sent"],["Aster","5","4"],["Cedar","0","0"]],
                  [724,684,644,604])
    second = table(commands,[["Lot","Due","Sent"],["Juniper","9","7"],["Maple","","3"]],
                   [492,452,412,372])
    yield drawing.case("intervening-narrative-boundary-v1",commands,[first,second],
                       [dict(text="Inspection narrative separates the queues",x=60,y=548)],
                       "Narrative between aligned report bodies stops assembly across the boundary.")

    commands = ["0.5 w"]
    first = table(commands,[["Area","Booked","Used"],["Bench","6","5"],["Shelf","0","0"]],
                  [720,680,640,600])
    second = table(commands,[["Area","Booked","Used"],["Rack","14","13"],["Cart","","2"]],
                   [548,508,468,428])
    yield drawing.case("repeated-header-separate-statements-v1",commands,[first,second],
                       [dict(text="Two independent allocation reports",x=100,y=760)],
                       "A new repeated header after a blank report gap starts a separate same-alignment table.")

    commands = ["0.5 w"]
    detached = table(commands,[["Unit","Ready","Pending"],["Sterile","11","2"],["Control","0","-"]],
                     [710,670,630,590])
    yield drawing.case("detached-label-fragment-boundary-v1",commands,[detached],
                       [dict(text="unassigned carrier notes",x=68,y=466),
                        dict(text="Labels below are not reconciled to a unit",x=60,y=420)],
                       "Detached label-like text beyond a large gap has no numeric row association and remains unclaimed prose.")

    commands = ["0.5 w",drawing.rule(54,682,558,682),drawing.rule(90,330,90,450),drawing.rule(90,330,260,330)]
    yield drawing.case("section-heading-page-prose-negative-v1",commands,[],
                       [dict(text="WORKSHOP OVERVIEW",x=54,y=712),
                        dict(text="Tools are checked before each workday",x=54,y=650),
                        dict(text="Cabinets hold sample materials only",x=54,y=610),
                        dict(text="No quantities are reported on this page",x=54,y=570)],
                       "Page prose with a section heading, horizontal rule and graphic axes establishes no numeric table.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    args = parser.parse_args()
    def retain(path,data):
        if path.exists():
            if path.read_bytes() != data:
                raise ValueError("frozen statement drawing differs: "+str(path))
        elif args.check:
            raise ValueError("frozen statement drawing missing: "+str(path))
        else:
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(data)
    def encoded(value):
        return (json.dumps(value,indent=2)+"\n").encode()
    manifest,hashes = [],{}
    for name,data,truth in cases():
        pdf_name,truth_name = "corpus/"+name+".pdf","truth/"+name+".json"
        retain(ROOT/pdf_name,data)
        truth_data = encoded(truth)
        retain(ROOT/truth_name,truth_data)
        hashes[pdf_name] = hashlib.sha256(data).hexdigest()
        hashes[truth_name] = hashlib.sha256(truth_data).hexdigest()
        manifest.append(dict(id=name,split="dev",pdf=pdf_name,truth=truth_name))
    data = encoded(manifest)
    retain(ROOT/"cases.json",data)
    hashes["cases.json"] = hashlib.sha256(data).hexdigest()
    hashes["generate.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    freeze = dict(version=1,files_sha256=hashes,
                  dependencies_sha256={str(DRAWING_PATH.relative_to(ROOT.parent)):hashlib.sha256(DRAWING_PATH.read_bytes()).hexdigest()},
                  controls=dict(region_tolerance_points=6,geometry_tolerance_points=2),
                  scope="Independent section-label/wrapped-row development drawings; no merged-cell, continuation or real holdout qualification.",
                  acceptance=["exact complete regular matrices including section labels and blank numeric cells",
                    "both label fragments and numeric baseline belong to their own physical row",
                    "same strict ownership, token inventory, region, source identity and lifecycle gates as table_regions",
                    "prose, new headers and detached text preserve boundaries and source coverage"])
    retain(ROOT/"freeze.json",encoded(freeze))
    print(json.dumps(dict(cases=len(manifest),freeze_sha256=hashlib.sha256(encoded(freeze)).hexdigest())))


if __name__ == "__main__":
    main()
