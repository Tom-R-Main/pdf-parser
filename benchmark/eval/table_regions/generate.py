#!/usr/bin/env python3
"""Freeze independent development drawings before any parser assessment."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def pdf(commands):
    content = ("\n".join(commands) + "\n").encode("ascii")
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
               b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>"]
    output, offsets = bytearray(b"%PDF-1.4\n"), [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(output)


def text(value, x, y, size=10):
    escaped = value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    return f"BT /F1 {size} Tf 1 0 0 1 {x:g} {y:g} Tm ({escaped}) Tj ET"


def rule(x0, y0, x1, y1):
    return f"{x0:g} {y0:g} m {x1:g} {y1:g} l S"


def box(values):
    return dict(zip(("x0", "y0", "x1", "y1"), values))


def table(commands, matrix, xs, ys, ruled=False, right_edges=None, centered_headers=False):
    if ruled:
        commands.extend(rule(x, ys[-1], x, ys[0]) for x in xs)
        commands.extend(rule(xs[0], y, xs[-1], y) for y in ys)
    rows = []
    for ri, values in enumerate(matrix):
        cells = []
        for ci, value in enumerate(values):
            if value:
                x = xs[ci] + 8
                if right_edges and ci:
                    x = right_edges[ci-1] - len(value) * 6
                if ri == 0 and centered_headers and ci:
                    x = (xs[ci] + xs[ci+1]) / 2 - len(value) * 3
                commands.append(text(value, x, ys[ri] - 22))
            cells.append(dict(text=value, row=ri, column=ci, rowspan=1, colspan=1))
        rows.append(dict(row_index=ri, cells=cells))
    return dict(column_count=len(xs)-1, rows=rows, topology_required=True,
                source_ownership_required=True, region=box([xs[0], ys[-1], xs[-1], ys[0]]))


def case(name, commands, tables, retained, explanation):
    # Retained prose is positioned outside the semantic table region. Its
    # horizontal interval can overlap the table without making it a cell.
    for item in retained:
        commands.append(text(item["text"], item["x"], item["y"]))
    prose = [dict(text=item["text"], region=box([item["x"]-2, item["y"]-5,
                      item["x"]+len(item["text"])*6+2, item["y"]+10])) for item in retained]
    return name, pdf(commands), dict(tables=tables, retained_prose=prose, explanation=explanation)


def cases():
    commands = ["0.5 w"]
    upper = table(commands, [["Channel","Planned","Spent"],["Mail","90","86"],
                  ["Calls","0",""],["Visits","15","(3)"]], [54,300,415,530], [724,680,636,592,548], True)
    lower = table(commands, [["Stock","Depot","Held","Free"],["Bolts","North","12","7"],
                  ["Cable","West","0","0"],["Tape","East","","5"]], [54,214,360,445,530], [464,424,384,344,304], True)
    yield case("stacked-different-grids", commands, [upper,lower],
               [dict(text="Batch reviewed independently",x=70,y=506)],
               "Separate stacked ruled tables retain different column sets and intervening prose.")

    commands = ["0.5 w",rule(54,740,540,740)]
    statement = table(commands, [["Item","Window A","Window B"],["Cash","1,275","1,190"],
                ["Goods","40","0"],["Total assets","1,315","1,190"],["Payables","(125)","(110)"],
                ["Reserve","","-"],["Balance","1,190","1,080"]], [54,340,440,540],
                [708,668,628,588,548,508,468,408], right_edges=[424,524])
    for y in (590,488,410,412):
        commands += [rule(340,y,424,y),rule(440,y,524,y)]
    yield case("partial-rules-statement",commands,[statement],
               [dict(text="Inventory reconciliation",x=160,y=752)],
               "Short subtotal underlines do not invent columns or fragment one statement.")

    commands = ["0.5 w"]
    allocation = table(commands, [["Team","Budget","Used","Left"],["Ops","80","76","4"],
                 ["Desk","9","0","9"],["Field","","(2)","0"]], [54,260,360,460,540],
                 [708,664,620,576,532], right_edges=[325,425,525], centered_headers=True)
    yield case("centered-title-body-alignment",commands,[allocation],
               [dict(text="Quarterly allocation review",x=200,y=746)],
               "Centered header words must fit columns supported by persistent body alignment.")

    commands = ["0.5 w"]
    income = table(commands, [["Item","June","May"],["Earned","640","625"],["Fees","35","20"],
             ["Total income","675","645"],["Wages","(310)","(305)"],["Rent","(90)","(90)"],
             ["Total costs","(400)","(395)"],["Net","275","250"]], [54,340,440,540],
             [708,672,636,600,534,498,462,426,390], right_edges=[424,524])
    for y in (580,442,392,394):
        commands += [rule(340,y,424,y),rule(440,y,524,y)]
    yield case("complete-section-statement",commands,[income],
               [dict(text="Service account summary",x=130,y=748)],
               "A larger section gap and subtotal bands retain the complete eight-row statement.")

    commands = ["0.5 w",rule(90,310,90,480),rule(90,310,270,310),rule(112,340,185,430)]
    yield case("prose-diagram-negative",commands,[],
               [dict(text="1. Review intake",x=54,y=700),dict(text="2. Verify the signed note",x=70,y=654),
                dict(text="3. Archive the receipt",x=60,y=603),dict(text="Trend sketch only",x=95,y=500)],
               "Graphic axes and numbered prose do not establish a table.")

    commands = ["0.5 w"]
    ruled = table(commands, [["Port","Active"],["Elm","8"],["Pine","0"]],
                  [54,300,530],[724,684,644,604],True)
    borderless = table(commands, [["Shift","Opened","Closed"],["Early","25","24"],["Late","","0"],
                      ["Total","25","24"]], [54,340,440,540],[486,450,414,378,342],right_edges=[424,524])
    yield case("mixed-ruled-borderless",commands,[ruled,borderless],
               [dict(text="New report begins below",x=70,y=550)],
               "A ruled table and a borderless table must coexist without suppressing either route.")

    commands = ["0.5 w"]
    small = table(commands, [["Unit","Ready","Held"],["Press","7","2"],["Lift","0",""]],
                  [160,330,425,520],[640,600,560,520],True)
    yield case("overlapping-width-prose",commands,[small],
               [dict(text="All units inspected before release",x=90,y=686),
                dict(text="No owner action remains",x=170,y=478)],
               "Prose overlapping the horizontal table extent remains outside the cells and table region.")

    commands = ["0.5 w"]
    first = table(commands, [["Task","Due","Done"],["Seal","11","9"],["Pack","0","0"]],
                  [54,340,440,540],[720,684,648,612],right_edges=[424,524])
    second = table(commands, [["Task","Due","Done"],["Load","17","15"],["Ship","","0"]],
                   [54,340,440,540],[506,470,434,398],right_edges=[424,524])
    yield case("adjacent-same-alignment",commands,[first,second],
               [dict(text="This section is a separate work queue",x=54,y=561)],
               "Same font and column alignment do not merge distinct reports across intervening prose.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    args = parser.parse_args()
    def retain(path,data):
        if path.exists():
            if path.read_bytes() != data:
                raise ValueError("frozen drawing differs: "+str(path))
        elif args.check:
            raise ValueError("frozen drawing missing: "+str(path))
        else:
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(data)
    def encoded(value):
        return (json.dumps(value,indent=2)+"\n").encode()
    manifest, hashes = [], {}
    for name,data,truth in cases():
        pdf_name, truth_name = "corpus/"+name+".pdf", "truth/"+name+".json"
        retain(ROOT/pdf_name,data)
        truth_bytes = encoded(truth)
        retain(ROOT/truth_name,truth_bytes)
        hashes[pdf_name] = hashlib.sha256(data).hexdigest()
        hashes[truth_name] = hashlib.sha256(truth_bytes).hexdigest()
        manifest.append(dict(id=name,split="dev",pdf=pdf_name,truth=truth_name))
    data = encoded(manifest)
    retain(ROOT/"cases.json",data)
    hashes["cases.json"] = hashlib.sha256(data).hexdigest()
    hashes["generate.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    freeze = dict(version=1,files_sha256=hashes,controls=dict(region_tolerance_points=6,geometry_tolerance_points=2),
                  scope="Independent synthetic development drawings; no holdout qualification or continuation claim.",
                  acceptance=["exact table count, regular occupancy, column extent and cell text",
                    "one source span owner per nonblank cell; blank differs from zero and dash",
                    "finite raw PDF geometry, bounded separate table regions",
                    "retained prose remains outside table cells", "both public JSONL lifecycle contracts"])
    retain(ROOT/"freeze.json",encoded(freeze))
    print(json.dumps(dict(cases=len(manifest),freeze_sha256=hashlib.sha256(encoded(freeze)).hexdigest())))


if __name__ == "__main__":
    main()
