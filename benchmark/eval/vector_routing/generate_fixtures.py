#!/usr/bin/env python3
"""Generate small path-only text controls without embedding a font program.

The default font is Bitstream Vera from the installed ReportLab distribution.
Only its simple TrueType glyph outlines become drawing operators in these PDFs.
An explicit --font permits regeneration without ReportLab. No packages are fetched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path


def number(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".") or "0"


class SimpleTrueType:
    def __init__(self, path: Path):
        self.data = path.read_bytes()
        count = self.u16(4)
        self.tables = {}
        for index in range(count):
            tag, _, offset, length = struct.unpack_from(">4sIII", self.data, 12 + index * 16)
            self.tables[tag.decode("ascii")] = (offset, length)
        head = self.tables["head"][0]
        self.units = self.u16(head + 18)
        long_offsets = self.i16(head + 50) == 1
        glyph_count = self.u16(self.tables["maxp"][0] + 4)
        loca = self.tables["loca"][0]
        self.offsets = [
            struct.unpack_from(">I", self.data, loca + index * 4)[0]
            if long_offsets else self.u16(loca + index * 2) * 2
            for index in range(glyph_count + 1)
        ]
        self.metrics_count = self.u16(self.tables["hhea"][0] + 34)
        cmap = self.tables["cmap"][0]
        formats = []
        for index in range(self.u16(cmap + 2)):
            platform, encoding, offset = struct.unpack_from(">HHI", self.data, cmap + 4 + index * 8)
            subtable = cmap + offset
            if self.u16(subtable) == 4 and platform in (0, 3):
                formats.append((platform == 3 and encoding == 1, subtable))
        if not formats:
            raise ValueError("This fixture generator requires a Unicode format-4 cmap")
        self.cmap = max(formats)[1]

    def u16(self, offset):
        return struct.unpack_from(">H", self.data, offset)[0]

    def i16(self, offset):
        return struct.unpack_from(">h", self.data, offset)[0]

    def glyph(self, character):
        code = ord(character)
        count = self.u16(self.cmap + 6) // 2
        ends = self.cmap + 14
        starts = ends + count * 2 + 2
        deltas = starts + count * 2
        ranges = deltas + count * 2
        for index in range(count):
            if self.u16(starts + index * 2) <= code <= self.u16(ends + index * 2):
                delta = self.i16(deltas + index * 2)
                distance = self.u16(ranges + index * 2)
                if distance == 0:
                    return (code + delta) & 0xFFFF
                value = self.u16(ranges + index * 2 + distance + 2 * (code - self.u16(starts + index * 2)))
                return ((value + delta) & 0xFFFF) if value else 0
        raise ValueError(f"Missing glyph {character!r}")

    def advance(self, glyph):
        return self.u16(self.tables["hmtx"][0] + min(glyph, self.metrics_count - 1) * 4)

    def contours(self, glyph):
        start, end = self.offsets[glyph:glyph + 2]
        if start == end:
            return []
        offset = self.tables["glyf"][0] + start
        contour_count = self.i16(offset)
        if contour_count < 0:
            raise ValueError("Composite glyphs are deliberately outside these ASCII fixtures")
        endpoints = [self.u16(offset + 10 + index * 2) for index in range(contour_count)]
        position = offset + 10 + contour_count * 2
        instruction_count = self.u16(position)
        position += 2 + instruction_count
        count = endpoints[-1] + 1
        flags = []
        while len(flags) < count:
            flag = self.data[position]
            position += 1
            flags.append(flag)
            if flag & 8:
                flags.extend([flag] * self.data[position])
                position += 1
        axes = []
        for short_bit, same_bit in ((2, 16), (4, 32)):
            values, value = [], 0
            for flag in flags:
                if flag & short_bit:
                    delta = self.data[position]
                    position += 1
                    value += delta if flag & same_bit else -delta
                elif not flag & same_bit:
                    value += self.i16(position)
                    position += 2
                values.append(value)
            axes.append(values)
        contours, begin = [], 0
        for end in endpoints:
            contours.append([(axes[0][index], axes[1][index], bool(flags[index] & 1))
                             for index in range(begin, end + 1)])
            begin = end + 1
        return contours

    def outline(self, text, x, y, size, compound=False, stroke=False):
        scale, cursor = size / self.units, x
        painted = []
        all_paths = []
        bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]
        for character in text:
            glyph = self.glyph(character)
            paths = []
            for contour in self.contours(glyph):
                points = [(cursor + px * scale, y + py * scale, on) for px, py, on in contour]
                for px, py, _ in points:
                    bounds = [min(bounds[0], px), min(bounds[1], py), max(bounds[2], px), max(bounds[3], py)]
                first, last = points[0], points[-1]
                if first[2]:
                    start, pending = first, points[1:] + [first]
                elif last[2]:
                    start, pending = last, points[:-1] + [last]
                else:
                    start = ((first[0] + last[0]) / 2, (first[1] + last[1]) / 2, True)
                    pending = points + [start]
                paths.append(f"{number(start[0])} {number(start[1])} m")
                previous, index = start, 0
                while index < len(pending):
                    current = pending[index]
                    if current[2]:
                        paths.append(f"{number(current[0])} {number(current[1])} l")
                        previous, index = current, index + 1
                    else:
                        following = pending[index + 1]
                        end = following if following[2] else (
                            (current[0] + following[0]) / 2, (current[1] + following[1]) / 2, True)
                        controls = (previous[0] + 2 / 3 * (current[0] - previous[0]),
                                    previous[1] + 2 / 3 * (current[1] - previous[1]),
                                    end[0] + 2 / 3 * (current[0] - end[0]),
                                    end[1] + 2 / 3 * (current[1] - end[1]), end[0], end[1])
                        paths.append(" ".join(map(number, controls)) + " c")
                        previous, index = end, index + (2 if following[2] else 1)
                paths.append("h")
            if paths:
                all_paths.extend(paths)
                painted.append("\n".join(paths) + ("\nS" if stroke else "\nf"))
            cursor += self.advance(glyph) * scale
        operators = "\n".join(all_paths) if compound else "\n".join(painted)
        return operators, [round(value, 6) for value in bounds]


def native(text, x=40, y=205, size=12, color="0 g"):
    escaped = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    return f"{color}\nBT /F1 {size} Tf 1 0 0 1 {x} {y} Tm ({escaped}) Tj ET"


def stream(content, extra=""):
    data = content.encode("ascii") if isinstance(content, str) else content
    return f"<< /Length {len(data)} {extra} >>\nstream\n".encode() + data + b"\nendstream"


def pdf(pages, form=None, image=None, rotation=0):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", None,
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
    extra_resources = ""
    if form is not None:
        objects.append(stream(form, "/Type /XObject /Subtype /Form /BBox [0 0 350 120] /Resources << >>"))
        extra_resources += f"/Fm {len(objects)} 0 R "
    if image is not None:
        objects.append(stream(image, "/Type /XObject /Subtype /Image /Width 20 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8"))
        extra_resources += f"/Im {len(objects)} 0 R "
    kids = []
    for content in pages:
        page_id = len(objects) + 1
        kids.append(f"{page_id} 0 R")
        resources = f"/Font << /F1 3 0 R >> /XObject << {extra_resources} >>"
        rotate = f"/Rotate {rotation} " if rotation else ""
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 300] {rotate}/Resources << {resources} >> /Contents {page_id + 1} 0 R >>".encode())
        objects.append(stream(content))
    objects[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(pages)} >>".encode()
    data, offsets = bytearray(b"%PDF-1.7\n"), []
    for index, value in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{index} 0 obj\n".encode() + value + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    data.extend("".join(f"{offset:010} 00000 n \n" for offset in offsets).encode())
    data.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(data)


def generate(font_path, output):
    face = SimpleTrueType(font_path)
    fixtures = []
    output.mkdir(parents=True, exist_ok=True)
    truth = output / "truth"
    truth.mkdir(exist_ok=True)

    def add(name, pages, outlined=(), native_text=(), expectation="candidate", boxes=(), truth_text=None, **resources):
        data = pdf(pages, **resources)
        if len(data) > 100_000:
            raise ValueError(f"{name} exceeds the small-fixture limit")
        (output / f"{name}.pdf").write_bytes(data)
        (truth / f"{name}.txt").write_text("\n".join(truth_text if truth_text is not None else [*native_text, *outlined]) + "\n")
        fixtures.append(dict(id=name, file=f"{name}.pdf", bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                             native_text=list(native_text), outlined_text=list(outlined),
                             routing_expectation=expectation, outlined_bboxes=list(boxes), pages=len(pages), rotation=resources.get("rotation", 0)))

    words, bounds = face.outline("VECTOR EVIDENCE", 40, 160, 28)
    cover = native("Native evidence remains.", y=250)
    add("outlined-text", [words], ["VECTOR EVIDENCE"], boxes=[bounds])
    add("mixed-native-outlines", [cover + "\n" + words], ["VECTOR EVIDENCE"], ["Native evidence remains."], boxes=[bounds])
    clipped_native_text = "A" * 40
    partial_native = "q 40 155 1 30 re W n\n" + native(clipped_native_text, 40, 160, 40) + "\nQ\n" + words
    add("partial-native-clip", [partial_native], ["VECTOR EVIDENCE"], [clipped_native_text], boxes=[bounds])
    chart, chart_bounds = face.outline("VECTOR", 160, 140, 24)
    label, label_bounds = face.outline("EVIDENCE", 160, 80, 24)
    add("chart-labels", [native("Chart caption.", y=250) + "\n1 w 40 50 m 380 50 l S 40 50 m 40 210 l S\n" + chart + "\n" + label],
        ["VECTOR", "EVIDENCE"], ["Chart caption."], boxes=[chart_bounds, label_bounds])
    form, _ = face.outline("VECTOR EVIDENCE", 0, 40, 28)
    add("transformed-form", [cover + "\nq 1.1 0 0 1.1 50 75 cm /Fm Do Q"], ["VECTOR EVIDENCE"], ["Native evidence remains."], form=form)
    add("sheared-form", [cover + "\nq 1.1 0.1 -0.1 1.1 50 75 cm /Fm Do Q"], ["VECTOR EVIDENCE"], ["Native evidence remains."], expectation="ambiguous", form=form)
    quarter_words, quarter_bounds = face.outline("VECTOR EVIDENCE", 30, 150, 24)
    raw_quarter_bounds = [round(320 - quarter_bounds[3], 6), quarter_bounds[0], round(320 - quarter_bounds[1], 6), quarter_bounds[2]]
    quarter_page = "q 0 1 -1 0 320 0 cm\n" + native("Native evidence remains.", 30, 220) + "\n" + quarter_words + "\nQ"
    add("quarter-turn-outlines", [quarter_page], ["VECTOR EVIDENCE"], ["Native evidence remains."], boxes=[raw_quarter_bounds], rotation=90)
    add("clipped-out", [cover + "\nq 20 20 10 10 re W n\n" + words + "\nQ"], native_text=["Native evidence remains."], expectation="no_candidate")
    add("thin-stroked-rule", [cover + "\n0.5 w 40 155 m 360 155 l S"], native_text=["Native evidence remains."], expectation="no_candidate")
    add("thin-filled-rule", [cover + "\n40 155 320 1 re f"], native_text=["Native evidence remains."], expectation="no_candidate")
    add("native-highlight", ["0.85 g 38 154 290 25 re f\n" + native("Native evidence remains.", y=160, size=20)],
        native_text=["Native evidence remains."], expectation="no_candidate")
    add("filled-box", [cover + "\n0.6 g 80 80 100 60 re f"], native_text=["Native evidence remains."], expectation="no_candidate")
    add("border", [cover + "\n1 w 40 60 320 120 re S"], native_text=["Native evidence remains."], expectation="no_candidate")
    logo = "140 170 m 153 135 l 190 135 l 160 113 l 173 78 l 140 100 l 107 78 l 120 113 l 90 135 l 127 135 l h f"
    add("single-logo", [cover + "\n" + logo], native_text=["Native evidence remains."], expectation="no_candidate")
    graphics = "\n".join(f"{40 + column * 30} {50 + row * 20} 8 8 re f" for row in range(6) for column in range(10))
    add("dense-graphics", [cover + "\n" + graphics], native_text=["Native evidence remains."], expectation="ambiguous")
    lower, lower_bounds = face.outline("VECTOR EVIDENCE", 40, 65, 28)
    repeated = cover + "\n" + words + "\n" + lower
    add("repeated-multipage", [repeated, repeated], ["VECTOR EVIDENCE"] * 4, ["Native evidence remains."] * 2,
        boxes=[bounds, lower_bounds, bounds, lower_bounds], truth_text=["Native evidence remains.", "VECTOR EVIDENCE", "VECTOR EVIDENCE"] * 2)
    rule_word = words + "\n0.4 w 38 172 m 360 172 l S"
    add("rule-through-outlines", [cover + "\n" + rule_word], ["VECTOR EVIDENCE"], ["Native evidence remains."], boxes=[bounds])
    stroked, stroked_bounds = face.outline("VECTOR EVIDENCE", 40, 160, 28, stroke=True)
    add("stroked-letterforms", [cover + "\n0.7 w\n" + stroked], ["VECTOR EVIDENCE"], ["Native evidence remains."], boxes=[stroked_bounds])
    compound, compound_bounds = face.outline("VECTOR EVIDENCE", 40, 160, 28, compound=True)
    add("compound-fill", [cover + "\n" + compound + "\nf"], ["VECTOR EVIDENCE"], ["Native evidence remains."], boxes=[compound_bounds])
    panel = compound + "\n40 60 320 99 re\nf\n" + native("Panel text.", 80, 100, color="1 g")
    add("fused-panel", [cover + "\n" + panel], ["VECTOR EVIDENCE"], ["Native evidence remains.", "Panel text."], expectation="ambiguous", boxes=[compound_bounds],
        truth_text=["Native evidence remains.", "VECTOR EVIDENCE", "Panel text."])
    add("image-overlap", [cover + "\nq 320 0 0 35 35 155 cm /Im Do Q\n" + words], ["VECTOR EVIDENCE"], ["Native evidence remains."],
        boxes=[bounds], image=b"\xff" * (20 * 8 * 3))
    capped = "\n".join(f"{10 + index % 100 * 4} {10 + index // 100 * 4} 2 2 re f" for index in range(700))
    add("shape-cap", [cover + "\n" + capped], native_text=["Native evidence remains."], expectation="limited")
    long_path = "\n".join(f"{10 + index % 100 * 3} {50 + index // 100 * 2} l" for index in range(600))
    add("segment-cap", [cover + "\n10 50 m\n" + long_path + "\nS"], native_text=["Native evidence remains."], expectation="limited")
    metadata = dict(generator="generate_fixtures.py", font="Bitstream Vera", font_sha256=hashlib.sha256(font_path.read_bytes()).hexdigest(),
                    font_program_embedded=False, font_license_file="font-license.txt", pdf_page_bbox=[0, 0, 420, 300], fixtures=fixtures)
    (output / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"fixtures": len(fixtures), "total_pdf_bytes": sum(item["bytes"] for item in fixtures)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent)
    args = parser.parse_args()
    if args.font is None:
        try:
            import reportlab
            args.font = Path(reportlab.__file__).resolve().parent / "fonts" / "Vera.ttf"
        except ImportError as error:
            raise SystemExit("Use an installed ReportLab Python or pass --font to an existing Bitstream Vera.ttf") from error
    generate(args.font, args.output_dir)


if __name__ == "__main__":
    main()
