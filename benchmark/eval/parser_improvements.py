#!/usr/bin/env python3
"""Independent public-boundary checks for glyph geometry and decoding budgets.

Small authored PDFs isolate the mechanisms. They establish neither real-world
accuracy nor a whole-process memory bound. Raw results go to a new directory.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[2]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def pdf(content, filter_name=None, media_box="0 0 300 300", unicode_map=None):
    font_extra = " /ToUnicode 6 0 R" if unicode_map else ""
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               f"<< /Type /Page /Parent 2 0 R /MediaBox [{media_box}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".encode(),
               f"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica{font_extra} >>".encode()]
    extra = f" /Filter /{filter_name}" if filter_name else ""
    objects.append(f"<< /Length {len(content)}{extra} >>\nstream\n".encode()+content+b"\nendstream")
    if unicode_map:
        objects.append(f"<< /Length {len(unicode_map)} >>\nstream\n".encode()+unicode_map+b"\nendstream")
    output, offsets = bytearray(b"%PDF-1.4\n"), [0]
    for index, obj in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode()+obj+b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects)+1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(output)


def geometry_cases():
    yield "long-span", pdf(b"BT /F1 12 Tf 20 240 Td (alpha beta gamma delta epsilon) Tj ET"), "alpha beta gamma delta epsilon"
    yield "rotation-45", pdf(b"BT /F1 12 Tf .70710678 .70710678 -.70710678 .70710678 90 90 Tm (Rotated words) Tj ET"), "Rotated words"
    yield "wrapped-lines", pdf(b"BT /F1 12 Tf 20 240 Td (First line words) Tj 0 -24 Td (Second line words) Tj ET"), ["First line words", "Second line words"]
    yield "actual-text", pdf(b"/Span << /ActualText (replacement phrase) >> BDC BT /F1 12 Tf 20 240 Td (X) Tj ET EMC"), "replacement phrase"
    cmap = b"""/CIDInit /ProcSet findresource begin 12 dict begin begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /LocalLigature def /CMapType 2 def
1 begincodespacerange <01> <01> endcodespacerange
1 beginbfchar <01> <00660069> endbfchar
endcmap CMapName currentdict /CMap defineresource pop end end
"""
    yield "ligature-map", pdf(b"BT /F1 12 Tf 20 240 Td <01> Tj ET", unicode_map=cmap), "fi"
    # A centered MediaBox keeps both writing directions painted at y=0.
    # Ordinary positive-only boxes clip one side of this diagnostic fixture.
    yield "opposite-axes", pdf(b"BT /F1 12 Tf 1 0 0 1 -100 0 Tm (FORWARD) Tj ET BT /F1 12 Tf -1 0 0 -1 100 0 Tm (REVERSE) Tj ET", media_box="-300 -300 300 300"), ["FORWARD", "REVERSE"]


def run(cli, path, fmt, options, output, label):
    command = [str(cli), "extract-adaptive", "--input", str(path), "--no-ocr", "--format", fmt, *options]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=30)
    (output / f"{label}.{fmt}.jsonl").write_text(completed.stdout)
    (output / f"{label}.{fmt}.stderr").write_text(completed.stderr)
    result = {"command": command, "exit_code": completed.returncode,
              "stdout_sha256": sha(completed.stdout.encode()), "stderr_sha256": sha(completed.stderr.encode()),
              "reports_decoded_limit": "OutputTooLarge" in completed.stderr}
    records = []
    try:
        records = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    except ValueError as error:
        result["json_error"] = str(error)
    return result, records


def successful(result, records, fmt, failures):
    if result["exit_code"] != 0:
        failures.append(f"{fmt}: CLI exited {result['exit_code']}")
        return False
    if "json_error" in result:
        failures.append(f"{fmt}: malformed JSONL")
        return False
    if not records or records[0].get("record_type") != "document_manifest":
        failures.append(f"{fmt}: missing first manifest")
        return False
    if any(record.get("errors") for record in records):
        failures.append(f"{fmt}: lifecycle contains errors")
    if fmt == "stream-jsonl" and (records[-1].get("record_type") != "document_finished" or records[-1].get("status") != "completed"):
        failures.append(f"{fmt}: missing completed document_finished")
    return True


def check(condition, message, failures):
    if not condition:
        failures.append(message)


def geometry_valid(span, failures):
    encoded = span["text"].encode()
    previous_end = 0
    for item in span.get("glyph_geometry", []):
        start, end = item.get("text_start_byte"), item.get("text_end_byte")
        if not (type(start) is int and type(end) is int and previous_end <= start < end <= len(encoded)):
            failures.append("invalid or overlapping glyph UTF-8 byte range")
            continue
        previous_end = end
        try:
            encoded[start:end].decode()
        except UnicodeError:
            failures.append("glyph range splits a UTF-8 codepoint")
        box = item.get("bbox", {})
        valid_box = all(type(box.get(key)) in (int, float) and math.isfinite(box[key]) for key in ("x0", "y0", "x1", "y1"))
        check(valid_box and box["x1"] >= box["x0"] and box["y1"] >= box["y0"], "invalid glyph bbox", failures)
        check(item.get("precision") in ("glyph", "replacement_group"), "unknown glyph precision", failures)
        quad = item.get("quad")
        if quad is not None:
            check(len(quad) == 4 and all(len(point) == 2 and all(type(v) in (int, float) and math.isfinite(v) for v in point) for point in quad), "invalid quad", failures)
        if item.get("precision") == "replacement_group":
            check(quad is None, "semantic replacement invented a precise quad", failures)


def geometry_checks(name, expected, spans, failures):
    texts = expected if isinstance(expected, list) else [expected]
    found = []
    for text in texts:
        candidates = [span for span in spans if span.get("text") == text]
        check(len(candidates) == 1, f"expected exactly one span with text {text!r}", failures)
        found.extend(candidates)
    for span in found:
        check(bool(span.get("glyph_geometry")), "requested geometry missing", failures)
        geometry_valid(span, failures)
    if not found:
        return
    if name == "long-span":
        span = found[0]
        start, end = span["text"].index("gamma"), span["text"].index("gamma")+5
        selected = [item for item in span.get("glyph_geometry", []) if item["text_start_byte"] >= start and item["text_end_byte"] <= end]
        covered = b"".join(span["text"].encode()[item["text_start_byte"]:item["text_end_byte"]] for item in selected)
        check(covered == b"gamma", "substring geometry does not cover gamma exactly", failures)
        if selected:
            width = max(item["bbox"]["x1"] for item in selected)-min(item["bbox"]["x0"] for item in selected)
            check(0 < width < (span["bbox"]["x1"]-span["bbox"]["x0"])*0.6, "substring geometry is not finer than span bbox", failures)
    elif name == "rotation-45":
        quads = [item["quad"] for item in found[0].get("glyph_geometry", []) if item.get("quad") is not None]
        check(bool(quads), "rotated text has no glyph quads", failures)
        check(any(abs(q[1][0]-q[0][0]) > 0.001 and abs(q[1][1]-q[0][1]) > 0.001 for q in quads), "rotation lost in axis-aligned quad", failures)
    elif name in ("actual-text", "ligature-map"):
        items = found[0].get("glyph_geometry", [])
        check(len(items) == 1, "source group was subdivided or duplicated", failures)
        if len(items) == 1:
            item = items[0]
            check((item["text_start_byte"], item["text_end_byte"]) == (0, len(expected.encode())), "source group byte range is not exact", failures)
            precision = "replacement_group" if name == "actual-text" else "glyph"
            check(item.get("precision") == precision, "incorrect group precision", failures)
            check((item.get("quad") is None) == (name == "actual-text"), "incorrect group quad availability", failures)
    elif name == "opposite-axes":
        check(not any("FORWARD" in span.get("text", "") and "REVERSE" in span.get("text", "") for span in spans), "opposite writing axes fused into one span", failures)


def evaluate(cli, output):
    output.mkdir(parents=True, exist_ok=False)
    report = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "cli_sha256": sha(cli.read_bytes()), "harness_sha256": sha(Path(__file__).read_bytes()),
              "geometry": [], "decode_limits": [], "scope": "generated mechanism checks; no real-document accuracy or process-memory qualification"}
    for name, data, expected in geometry_cases():
        path = output / f"{name}.pdf"
        path.write_bytes(data)
        entry = {"id": name, "input_sha256": sha(data), "runs": {}, "failures": []}
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            plain, plain_records = run(cli, path, fmt, [], output, name+".default")
            enabled, enabled_records = run(cli, path, fmt, ["--include-glyph-geometry"], output, name+".geometry")
            entry["runs"][fmt] = {"default": plain, "geometry": enabled}
            if not successful(plain, plain_records, fmt, entry["failures"]) or not successful(enabled, enabled_records, fmt, entry["failures"]):
                continue
            plain_spans = [r for r in plain_records if r.get("record_type") == "span"]
            spans = [r for r in enabled_records if r.get("record_type") == "span"]
            check(all(r.get("glyph_geometry") == [] for r in plain_spans), f"{fmt}: geometry not empty by default", entry["failures"])
            strip = lambda rs: [{k: v for k, v in r.items() if k != "glyph_geometry"} for r in rs]
            check(strip(plain_spans) == strip(spans), f"{fmt}: geometry changed text, identity or existing source metadata", entry["failures"])
            check(enabled_records[0].get("text_contract", {}).get("geometry", {}).get("optional_glyph_geometry") is True, f"{fmt}: missing optional geometry contract", entry["failures"])
            geometry_checks(name, expected, spans, entry["failures"])
        report["geometry"].append(entry)
    decoded = b"% padding preserves one simple content stream\n" + b" \n"*4096 + b"BT /F1 12 Tf 20 240 Td (bounded decoding sentinel) Tj ET\n"
    for encoding, encoded, filter_name in (("flate", zlib.compress(decoded), "FlateDecode"), ("raw", decoded, None)):
        data = pdf(encoded, filter_name)
        path = output / f"decoded-{encoding}.pdf"
        path.write_bytes(data)
        entry = {"id": encoding, "input_sha256": sha(data), "decoded_content_bytes": len(decoded), "runs": {}, "failures": []}
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            for label, cap, reverse in (("below", len(decoded)-1, False), ("below-order-reversed", len(decoded)-1, True), ("exact", len(decoded), False), ("above", len(decoded)+1, False)):
                options = ["--max-decoded-stream-bytes", str(cap), "--permissive"] if reverse else ["--permissive", "--max-decoded-stream-bytes", str(cap)]
                result, records = run(cli, path, fmt, options, output, f"decoded-{encoding}.{label}")
                entry["runs"][fmt+"."+label] = result
                if label.startswith("below"):
                    check(result["exit_code"] != 0, f"{fmt}/{label}: decoder limit recovered to success", entry["failures"])
                    check(result["reports_decoded_limit"], f"{fmt}/{label}: failure was not reported as OutputTooLarge", entry["failures"])
                    check(not any(r.get("record_type") == "document_finished" and r.get("status") == "completed" for r in records), f"{fmt}/{label}: falsely completed document", entry["failures"])
                elif successful(result, records, fmt, entry["failures"]):
                    check(any(r.get("record_type") == "span" and "bounded decoding sentinel" in r.get("text", "") for r in records), f"{fmt}/{label}: missing text below sufficient decoding cap", entry["failures"])
        report["decode_limits"].append(entry)
    report["passed"] = all(not entry["failures"] for family in ("geometry", "decode_limits") for entry in report[family])
    (output / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "zig-out/bin/pdf-parser")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = evaluate(args.cli.resolve(), args.output.resolve())
    print(json.dumps({"passed": report["passed"], **{family: [{"id": e["id"], "failures": e["failures"]} for e in report[family]] for family in ("geometry", "decode_limits")}}, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
