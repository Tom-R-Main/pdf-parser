#!/usr/bin/env python3
"""Create an independent, frozen reading-order experiment without dependencies."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PREFIX = "benchmark/eval/reading_order_next"


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def page(items, graphics="", transformed=False, reverse=False):
    return dict(items=items, graphics=graphics, transformed=transformed, reverse=reverse)


def fixtures():
    result = []
    for split, prefix, shift in (("dev", "DEV", 0), ("holdout", "SEALED", 11)):
        def texts(specs):
            return [(name, f"{prefix} {name.replace('_', ' ')}", x + shift, y, size)
                    for name, x, y, size in specs]
        ruled = texts([("introduction", 60, 750, 12), ("header_left", 75, 680, 12),
                       ("header_right", 335, 680, 12), ("row_one_left", 75, 630, 12),
                       ("row_one_right", 335, 630, 12), ("row_two_left", 75, 580, 12),
                       ("row_two_right", 335, 580, 12), ("conclusion", 60, 480, 12)])
        grid = "0.7 w\n" + "\n".join(
            [f"60 {y} m 552 {y} l S" for y in (700, 650, 600, 550)] +
            [f"{x} 550 m {x} 700 l S" for x in (60, 306, 552)])
        sections = texts([("section_one", 60, 750, 18), ("first_left_open", 60, 700, 12),
                          ("first_left_close", 60, 650, 12), ("first_right_open", 330, 700, 12),
                          ("first_right_close", 330, 650, 12), ("section_two", 60, 560, 18),
                          ("second_left_open", 60, 510, 12), ("second_left_close", 60, 460, 12),
                          ("second_right_open", 330, 510, 12), ("second_right_close", 330, 460, 12)])
        linear = texts([("opening", 60, 740, 12), ("middle", 60, 610, 12), ("closing", 60, 480, 12)])
        columns = texts([("left_open", 60, 730, 12), ("left_close", 60, 630, 12),
                         ("right_open", 330, 730, 12), ("right_close", 330, 630, 12)])
        # Lines crossing text or lying inside graphics must not manufacture a new text region.
        rejected = "0.5 w 40 733 m 550 733 l S\n40 430 220 110 re S\n150 440 m 150 530 l S"
        continuation = [page(texts([("page_one_open", 60, 740, 12), ("page_one_continue", 60, 580, 12)]), reverse=True),
                        page(texts([("page_two_resume", 60, 740, 12), ("page_two_close", 60, 580, 12)]), reverse=True)]
        cases = [("ruled-table-prose", [page(ruled, grid, reverse=True)]),
                 ("section-column-reset", [page(sections, reverse=True)]),
                 ("reverse-stream", [page(linear, reverse=True)]),
                 ("accepted-separator", [page(columns, "0.5 w 300 580 m 300 760 l S", reverse=True)]),
                 ("rejected-separators-graphic", [page(linear, rejected, reverse=True)]),
                 ("quarter-turn-crop-userunit", [page(linear, transformed=True, reverse=True)]),
                 ("multipage-continuation", continuation)]
        for family, pages in cases:
            nodes = [dict(id=item[0], text_anchor=item[1], page_index=index)
                     for index, p in enumerate(pages) for item in p["items"]]
            edges = [[a["id"], b["id"]] for a, b in zip(nodes, nodes[1:])]
            local = [edge for edge in edges if next(n["page_index"] for n in nodes if n["id"] == edge[0]) ==
                     next(n["page_index"] for n in nodes if n["id"] == edge[1])]
            result.append(dict(doc_id=f"order-next-{family}-{split}", family=family, split=split,
                               pages=pages, truth=dict(version=1, nodes=nodes, required_precedence=edges,
                               page_local_precedence=local, document_precedence=[e for e in edges if e not in local])))
    return result


def build_pdf(pages):
    # Each anchor uses its own positioned text object; no line is pre-concatenated.
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"", b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    page_numbers = []
    for p in pages:
        page_number = len(objects) + 1
        page_numbers.append(page_number)
        geometry = "/MediaBox [0 0 612 792]"
        if p["transformed"]:
            geometry = "/MediaBox [0 0 426 346] /CropBox [10 20 406 326] /Rotate 90 /UserUnit 2"
        objects.append(f"<< /Type /Page /Parent 2 0 R {geometry} /Resources << /Font << /F1 3 0 R >> >> /Contents {page_number+1} 0 R >>".encode())
        content = ["q"]
        if p["transformed"]:
            content.append("0 0.5 -0.5 0 406 20 cm")
        content.append(p["graphics"])
        items = list(reversed(p["items"])) if p["reverse"] else p["items"]
        for _, text, x, y, size in items:
            content.append(f"BT /F1 {size} Tf 1 0 0 1 {x} {y} Tm ({text}) Tj ET")
        content.append("Q")
        stream = ("\n".join(content) + "\n").encode("ascii")
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"endstream")
    kids = " ".join(f"{n} 0 R" for n in page_numbers)
    objects[1] = f"<< /Type /Pages /Count {len(pages)} /Kids [{kids}] >>".encode()
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(out))
        out.extend(f"{index} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(out)
    out.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        out.extend(f"{offset:010d} 00000 n \n".encode())
    out.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(out)


def generated():
    files = {}
    manifest = ["# category\tdoc_id\tpdf_path\ttruth_text_path\ttruth_table_json_path_optional\ttruth_reading_order_path_optional\ttruth_formula_path_optional\ttruth_formula_json_path_optional\ttruth_form_json_path_optional\ttruth_reading_graph_path_optional"]
    metadata = []
    for fixture in fixtures():
        doc_id, truth = fixture["doc_id"], fixture["truth"]
        files[f"corpus/{doc_id}.pdf"] = build_pdf(fixture["pages"])
        files[f"truth/{doc_id}.json"] = encoded(truth)
        files[f"page_text/{doc_id}.txt"] = ("\n".join(n["text_anchor"] for n in truth["nodes"]) + "\n").encode()
        # Internal graph truth deliberately excludes cross-page document edges.
        graph = {k: truth[k] for k in ("version", "nodes")}
        graph.update(required_precedence=truth["page_local_precedence"], forbidden_precedence=[], ambiguous_pairs=[], relations=[], valid_orders=[])
        files[f"graph_truth/{doc_id}.json"] = encoded(graph)
        manifest.append("\t".join(["visual_truth", doc_id, f"{PREFIX}/corpus/{doc_id}.pdf", f"{PREFIX}/page_text/{doc_id}.txt", "", "", "", "", "", f"{PREFIX}/graph_truth/{doc_id}.json"]))
        metadata.append(json.dumps(dict(doc_id=doc_id, family=fixture["family"], reading_order_split=fixture["split"], expected_ocr_pages=0), sort_keys=True))
    files["manifest.tsv"] = ("\n".join(manifest) + "\n").encode()
    files["metadata.jsonl"] = ("\n".join(metadata) + "\n").encode()
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Check frozen bytes without writing")
    args = parser.parse_args()
    files = generated()
    freeze = dict(version=1, scope="fresh experiment; previous frozen stop rules remain in force",
                  policy="legacy output remains default; graph diagnostics cannot authorize promotion; retain heldout failures without retuning",
                  acceptance=dict(anchors="exactly once on declared page in spans and blocks", emitted_order="all page-local and document precedence pairs in blocks", lifecycle="manifest first; sequential page starts/finishes; completed document last", diagnostics="page-local only, report scores separately from emitted order"),
                  sha256={name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())})
    frozen = ROOT / "freeze.json"
    if frozen.exists() and frozen.read_bytes() != encoded(freeze):
        raise SystemExit("Frozen experiment changed; do not retune heldout truth or overwrite freeze")
    for name, data in files.items():
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit(f"Stale generated file: {name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if args.check:
        if not frozen.exists():
            raise SystemExit("Missing pre-evaluation freeze")
    else:
        frozen.write_bytes(encoded(freeze))
    print(f"{'Checked' if args.check else 'Frozen'} {len(files)} deterministic files, 14 fixtures")


if __name__ == "__main__":
    main()
