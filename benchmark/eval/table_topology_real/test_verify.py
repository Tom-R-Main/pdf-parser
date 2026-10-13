"""Regression tests for strict partial-region qualification, independent of PDFs."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify


def envelope(kind, page=None):
    record = dict(record_type=kind, schema_name=kind, schema_version="0.19.1", source_id="case", document_id="doc",
                  provenance=dict(source_id="case", input_sha256="a" * 64, document_id="doc", page_index=page, span_ids=[]))
    if page is not None:
        record["page_index"] = page
    return record


def fixture(positive=False):
    source = dict(id="source", filename="source.pdf", sha256="a" * 64, page_count=5, issuer="issuer", template_family="template")
    case = dict(id="case", source_id="source", split="dev", pages=[3, 4], tables=[
        dict(id="left", page_index=2, bbox=[0, 0, 100, 100], column_count=2,
             rows=[dict(tokens="Label 0"), dict(tokens="Dash -"), dict(tokens="Missing NA")]),
        dict(id="right", page_index=3, bbox=[0, 0, 100, 100], column_count=2,
             rows=[dict(tokens="Next 17")])], relations=[dict(**{"from": "left", "to": "right", "continues": positive})])
    manifest = envelope("document_manifest")
    manifest.update(page_count=5, input_sha256=source["sha256"])
    records = [manifest]
    for ti, (page, pairs) in enumerate(((2, [("Label", "0"), ("Dash", "-"), ("Missing", "NA"), ("Blank", "")]),
                                       (3, [("Next", "17")]))):
        table = envelope("table", page)
        table.update(table_id=f"table-{ti}", logical_table_id="logical" if positive else f"logical-{ti}", table_part_index=ti if positive else 0,
                     continued_from_table_id="table-0" if positive and ti else None,
                     continued_to_table_id="table-1" if positive and not ti else None,
                     column_count=2, bbox=dict(x0=0, y0=0, x1=100, y1=100), rows=[], source_span_ids=[])
        for ri, pair in enumerate(pairs):
            row = dict(row_index=ri, cells=[])
            for ci, text in enumerate(pair):
                sid = f"span-{ti}-{ri}-{ci}"
                cell = envelope("table_cell", page)
                cell.update(cell_id=f"cell-{ti}-{ri}-{ci}", row=ri, column=ci, rowspan=1, colspan=1, text=text,
                            source_span_ids=[sid] if text else [], reconciled_block_ids=[])
                cell["provenance"]["span_ids"] = cell["source_span_ids"][:]
                row["cells"].append(cell)
                if text:
                    span = envelope("span", page)
                    span.update(span_id=sid, text=text)
                    records.append(span)
                    table["source_span_ids"].append(sid)
            table["rows"].append(row)
        records.append(table)
    return records, case, source


def stream(records, case):
    output = [records[0]]
    for page in range(case["pages"][0] - 1, case["pages"][1]):
        start = envelope("page_started", page)
        start["status"] = "running"
        output.append(start)
        output.extend(r for r in records[1:] if r.get("page_index") == page)
        end = envelope("page_finished", page)
        end["status"] = "completed"
        output.append(end)
    end = envelope("document_finished")
    end["status"] = "completed"
    output.append(end)
    return output


class ScoreTests(unittest.TestCase):
    def assert_failed(self, records, case, source, contains, fmt="artifact-jsonl"):
        result = verify.score(records, case, source, fmt)
        self.assertEqual(result["status"], "failed", result)
        self.assertTrue(any(contains in failure for failure in result["failures"]), result["failures"])

    def test_valid_negative_and_reciprocal_positive_in_both_formats(self):
        for positive in (False, True):
            records, case, source = fixture(positive)
            for fmt, output in (("artifact-jsonl", records), ("stream-jsonl", stream(records, case))):
                result = verify.score(output, case, source, fmt)
                self.assertEqual(result["status"], "verified", result["failures"])

    def test_missing_tables_cannot_pass_negative_relation(self):
        records, case, source = fixture()
        records = [r for r in records if r["record_type"] != "table"]
        self.assert_failed(records, case, source, "both selected tables present")

    def test_one_missing_table_cannot_pass_negative_relation(self):
        records, case, source = fixture()
        records = [r for r in records if r.get("table_id") != "table-1"]
        self.assert_failed(records, case, source, "both selected tables present")

    def test_one_way_positive_and_nonconsecutive_parts_fail(self):
        records, case, source = fixture(True)
        tables = [r for r in records if r["record_type"] == "table"]
        tables[1]["continued_from_table_id"] = None
        self.assert_failed(records, case, source, "reciprocal continuation")
        tables[1]["continued_from_table_id"] = "table-0"
        tables[1]["table_part_index"] = 3
        self.assert_failed(records, case, source, "consecutive parts")

    def test_false_continuation_and_logical_aliases_fail(self):
        records, case, source = fixture(True)
        case["relations"][0]["continues"] = False
        self.assert_failed(records, case, source, "separate logical identity")
        self.assert_failed(records, case, source, "no cross continuation links")

    def test_page_local_span_ids_must_be_global_and_links_on_same_page(self):
        records, case, source = fixture()
        spans = [r for r in records if r["record_type"] == "span"]
        spans[-1]["span_id"] = spans[0]["span_id"]
        self.assert_failed(records, case, source, "unique global span identity")
        records, case, source = fixture()
        spans = [r for r in records if r["record_type"] == "span"]
        spans[0]["page_index"] = 3
        spans[0]["provenance"]["page_index"] = 3
        self.assert_failed(records, case, source, "nondangling page-local span")

    def test_blank_zero_dash_and_na_remain_distinct(self):
        for index, replacement in ((0, ""), (1, "0"), (2, "0")):
            records, case, source = fixture()
            table = next(r for r in records if r["record_type"] == "table")
            table["rows"][index]["cells"][1]["text"] = replacement
            self.assert_failed(records, case, source, "literal selected row")
        records, case, source = fixture()
        table = next(r for r in records if r["record_type"] == "table")
        blank = table["rows"][3]["cells"][1]
        blank["source_span_ids"] = table["rows"][0]["cells"][1]["source_span_ids"][:]
        blank["provenance"]["span_ids"] = blank["source_span_ids"][:]
        self.assert_failed(records, case, source, "blank owns no text")

    def test_blank_cell_cannot_claim_reconciled_block(self):
        records, case, source = fixture()
        table = next(r for r in records if r["record_type"] == "table")
        table["rows"][3]["cells"][1]["reconciled_block_ids"] = ["block-1"]
        self.assert_failed(records, case, source, "blank owns no blocks")

    def test_whitespace_only_normalization_and_token_boundaries(self):
        records, case, source = fixture()
        case["tables"][0]["rows"][0]["tokens"] = " Label\t0\n"
        self.assertEqual(verify.score(records, case, source)["status"], "verified")
        case["tables"][0]["rows"][0]["tokens"] = "Label 0.0"
        self.assert_failed(records, case, source, "literal selected row")

    def test_prefix_does_not_fuse_independent_panel_rows(self):
        records, case, source = fixture()
        case["tables"][0]["rows"] = [dict(tokens="Label", prefix=True)]
        self.assertEqual(verify.score(records, case, source)["status"], "verified")
        case["tables"][0]["rows"][0]["tokens"] = "Label 0 Dash -"
        self.assert_failed(records, case, source, "literal selected row")

    def test_physical_merged_two_and_three_child_headers(self):
        records, case, source = fixture()
        table = next(r for r in records if r["record_type"] == "table")
        table["column_count"] = 5
        case["tables"][0]["column_count"] = 5
        header_row = dict(row_index=0, cells=[])
        for ci, (text, column, width) in enumerate((("Coefficient of variation", 0, 2), ("Standard error", 2, 3))):
            sid = f"header-span-{ci}"
            span = envelope("span", 2)
            span.update(span_id=sid, text=text)
            records.insert(1, span)
            cell = envelope("table_cell", 2)
            cell.update(cell_id=f"header-{ci}", row=0, column=column, rowspan=1, colspan=width, text=text, source_span_ids=[sid])
            cell["provenance"]["span_ids"] = [sid]
            header_row["cells"].append(cell)
            table["source_span_ids"].append(sid)
        for row in table["rows"]:
            row["row_index"] += 1
            for cell in row["cells"]:
                cell["row"] += 1
        table["rows"].insert(0, header_row)
        case["tables"][0]["headers"] = [dict(text=c["text"], row=0, column=c["column"], rowspan=1, colspan=c["colspan"]) for c in header_row["cells"]]
        self.assertEqual(verify.score(records, case, source)["status"], "verified")
        header_row["cells"][0]["colspan"] = 1
        self.assert_failed(records, case, source, "physical merged header")
        header_row["cells"][0]["colspan"] = 3
        self.assert_failed(records, case, source, "bounded physical topology")

    def test_frozen_candidate_coverage_is_bidirectional_and_ambiguity_fails(self):
        records, case, source = fixture()
        table = next(r for r in records if r["record_type"] == "table")
        table["bbox"] = dict(x0=0, y0=0, x1=1000, y1=1000)
        self.assert_failed(records, case, source, "exactly one frozen-region candidate")
        table["bbox"] = dict(x0=0, y0=0, x1=20, y1=20)
        self.assert_failed(records, case, source, "exactly one frozen-region candidate")
        table["bbox"] = dict(x0=0, y0=0, x1=100, y1=100)
        duplicate = copy.deepcopy(table)
        duplicate["table_id"] = "other"
        records.append(duplicate)
        self.assert_failed(records, case, source, "exactly one frozen-region candidate")

    def test_original_page_hash_and_source_identity(self):
        records, case, source = fixture()
        records[0]["page_count"] = 2
        records[0]["input_sha256"] = "wrong"
        records[-1]["source_id"] = "other"
        self.assert_failed(records, case, source, "original document page count")
        self.assert_failed(records, case, source, "whole-file input SHA256")
        self.assert_failed(records, case, source, "source identity")

    def test_selected_pages_keep_original_stream_indices(self):
        records, case, source = fixture()
        output = stream(records, case)
        for record in output:
            if "page_index" in record:
                record["page_index"] -= 2
                record["provenance"]["page_index"] -= 2
        self.assert_failed(output, case, source, "original selected page", "stream-jsonl")

    def test_lifecycle_missing_duplicate_reordered_and_after_end_fail(self):
        records, case, source = fixture()
        output = stream(records, case)
        broken = [r for r in output if r["record_type"] != "document_finished"]
        self.assert_failed(broken, case, source, "complete selected-page stream", "stream-jsonl")
        broken = output + [output[-1]]
        self.assert_failed(broken, case, source, "before document completion", "stream-jsonl")
        broken = copy.deepcopy(output)
        finish = next(r for r in broken if r["record_type"] == "page_finished")
        finish["page_index"] = 3
        self.assert_failed(broken, case, source, "page finish", "stream-jsonl")
        self.assert_failed(output, case, source, "batch lifecycle")

    def test_boolean_numeric_slots_and_nonfinite_geometry_fail(self):
        for field in ("column_count", "table_part_index"):
            records, case, source = fixture()
            table = next(r for r in records if r["record_type"] == "table")
            table[field] = True
            self.assertEqual(verify.score(records, case, source)["status"], "failed")
        for field in ("row", "column", "rowspan", "colspan"):
            records, case, source = fixture()
            table = next(r for r in records if r["record_type"] == "table")
            table["rows"][0]["cells"][0][field] = True
            self.assert_failed(records, case, source, "numeric physical slots")
        records, case, source = fixture()
        table = next(r for r in records if r["record_type"] == "table")
        table["bbox"]["x0"] = float("nan")
        self.assert_failed(records, case, source, "table bounds")

    def test_actual_public_bbox_objects_and_malformed_boxes(self):
        records, case, source = fixture()
        self.assertEqual(verify.score(records, case, source)["status"], "verified")
        table = next(r for r in records if r["record_type"] == "table")
        del table["bbox"]["x1"]
        self.assert_failed(records, case, source, "table bounds")
        table["bbox"]["x1"] = 100
        table["bbox"]["x0"] = False
        self.assert_failed(records, case, source, "table bounds")

    def test_array_shaped_public_bbox_fails_in_both_formats(self):
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            records, case, source = fixture()
            table = next(r for r in records if r["record_type"] == "table")
            table["bbox"] = [table["bbox"][key] for key in ("x0", "y0", "x1", "y1")]
            if fmt == "stream-jsonl":
                records = stream(records, case)
            self.assert_failed(records, case, source, "table bounds", fmt)

    def test_malformed_blank_placeholder_cannot_hide_under_merged_cell(self):
        records, case, source = fixture()
        table = next(r for r in records if r["record_type"] == "table")
        merged, placeholder = table["rows"][0]["cells"]
        merged["colspan"] = 2
        placeholder.update(text="", source_span_ids=[], colspan=5)
        placeholder["provenance"]["span_ids"] = []
        self.assert_failed(records, case, source, "physical slots within table")

    def test_no_ocr_command_uses_original_pdf_and_selected_range(self):
        _, case, _ = fixture()
        command = verify.extraction_command("parser", "original.pdf", case, "stream-jsonl")
        self.assertIn("--no-ocr", command)
        self.assertNotIn("--disable-ocr", command)
        self.assertEqual(command[command.index("--pages") + 1], "3-4")
        self.assertEqual(command[command.index("--source-id") + 1], "case")


class CorpusTests(unittest.TestCase):
    def make_corpus(self, root):
        _, case, source = fixture()
        (root / "sources.json").write_text(json.dumps([source]))
        (root / "cases.json").write_text(json.dumps([case]))
        freeze = dict(files_sha256={name: verify.sha(root / name) for name in ("sources.json", "cases.json")},
                      controls=dict(min_region_coverage=0.7, min_table_coverage=0.7))
        (root / "freeze.json").write_text(json.dumps(freeze))
        return freeze

    def test_current_real_pool_loads_with_frozen_sources_and_cases(self):
        sources, cases, freeze = verify.load_corpus()
        self.assertEqual(len(sources), 3)
        self.assertEqual(len(cases), 3)
        self.assertEqual(sum(len(case["tables"]) for case in cases), 11)
        self.assertTrue({"dev", "holdout"} == {case["split"] for case in cases})
        self.assertEqual(freeze["controls"], dict(min_region_coverage=0.7, min_table_coverage=0.7))

    def main_fixture(self, directory):
        parent = Path(directory)
        root = parent / "corpus"
        root.mkdir()
        self.make_corpus(root)
        (parent / "table_compare.py").write_text("# comparator identity test\n")
        originals = parent / "originals"
        originals.mkdir()
        (originals / "source.pdf").write_bytes(b"unchanged local original")
        output = parent / "evidence"
        args = ["verify.py", "--cli", sys.executable, "--split", "dev", "--source-root", str(originals), "--output", str(output)]
        return root, originals, output, args

    def test_wrong_input_hash_retains_operational_failure_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _, output, args = self.main_fixture(directory)
            corpus = verify.load_corpus(root)
            with mock.patch.object(verify, "ROOT", root), mock.patch.object(verify, "load_corpus", return_value=corpus), mock.patch.object(sys, "argv", args):
                self.assertEqual(verify.main(), 1)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("wrong whole-file input hash", report["failures"][0])
            self.assertTrue((output / "identity.json").is_file())
            self.assertEqual(report["total"], 0)

    def test_existing_evidence_directory_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            _, _, output, args = self.main_fixture(directory)
            output.mkdir()
            (output / "report.json").write_text("original evidence")
            with mock.patch.object(sys, "argv", args), self.assertRaises(FileExistsError):
                verify.main()
            self.assertEqual((output / "report.json").read_text(), "original evidence")

    def test_input_mutation_stops_after_first_format_and_retains_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root, originals, output, args = self.main_fixture(directory)
            sources, cases, freeze = verify.load_corpus(root)
            digest = verify.sha(originals / "source.pdf")
            sources[0]["sha256"] = digest
            records, _, _ = fixture()
            records[0]["input_sha256"] = digest
            for record in records:
                record["provenance"]["input_sha256"] = digest
                for row in record.get("rows", []):
                    for cell in row["cells"]:
                        cell["provenance"]["input_sha256"] = digest

            def mutate(command, stdout_path, stderr_path, timeout):
                stdout_path.write_text("\n".join(json.dumps(r) for r in records) + "\n")
                stderr_path.write_text("")
                (originals / "source.pdf").write_bytes(b"changed during extraction")
                return dict(exit_code=0, failure=None, stdout_bytes=stdout_path.stat().st_size)

            with mock.patch.object(verify, "ROOT", root), mock.patch.object(verify, "load_corpus", return_value=(sources, cases, freeze)), mock.patch.object(verify, "run_command", side_effect=mutate) as runner, mock.patch.object(sys, "argv", args):
                self.assertEqual(verify.main(), 1)
                self.assertEqual(runner.call_count, 1)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["total"], 1)
            self.assertIn("source changed during verification", report["results"][0]["failures"])
            self.assertTrue((output / "case-artifact-jsonl.jsonl").is_file())
            self.assertFalse((output / "case-stream-jsonl.jsonl").exists())

    def test_interrupt_retains_completed_results_active_command_and_raw_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root, originals, output, args = self.main_fixture(directory)
            sources, cases, freeze = verify.load_corpus(root)
            digest = verify.sha(originals / "source.pdf")
            sources[0]["sha256"] = digest
            records, _, _ = fixture()
            records[0]["input_sha256"] = digest
            for record in records:
                record["provenance"]["input_sha256"] = digest
                for row in record.get("rows", []):
                    for cell in row["cells"]:
                        cell["provenance"]["input_sha256"] = digest
            calls = []

            def interrupt_second(command, stdout_path, stderr_path, timeout):
                calls.append(command)
                stderr_path.write_text("")
                if len(calls) == 2:
                    stdout_path.write_text("partial interrupted output\n")
                    raise KeyboardInterrupt()
                stdout_path.write_text("\n".join(json.dumps(r) for r in records) + "\n")
                return dict(exit_code=0, failure=None, stdout_bytes=stdout_path.stat().st_size)

            with mock.patch.object(verify, "ROOT", root), mock.patch.object(verify, "load_corpus", return_value=(sources, cases, freeze)), mock.patch.object(verify, "run_command", side_effect=interrupt_second), mock.patch.object(sys, "argv", args):
                self.assertEqual(verify.main(), 130)
            report = json.loads((output / "report.json").read_text())
            self.assertTrue(report["interrupted"])
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["total"], 1)
            self.assertEqual(report["verified"], 1)
            self.assertEqual(report["active_execution"]["format"], "stream-jsonl")
            self.assertEqual((output / "case-stream-jsonl.jsonl").read_text(), "partial interrupted output\n")
            self.assertTrue((output / "case-artifact-jsonl.report.json").is_file())

    def test_frozen_truth_and_selector_drift_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            freeze = self.make_corpus(root)
            self.assertEqual(len(verify.load_corpus(root)[1]), 1)
            (root / "cases.json").write_text("[]")
            with self.assertRaisesRegex(ValueError, "corpus drift"):
                verify.load_corpus(root)
            freeze = self.make_corpus(root)
            freeze["controls"]["min_region_coverage"] = 0.5
            (root / "freeze.json").write_text(json.dumps(freeze))
            with self.assertRaisesRegex(ValueError, "selector"):
                verify.load_corpus(root)

    def test_binding_paths_cannot_escape_corpus(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            freeze = self.make_corpus(root)
            freeze["files_sha256"]["../elsewhere"] = "a" * 64
            (root / "freeze.json").write_text(json.dumps(freeze))
            with self.assertRaisesRegex(ValueError, "corpus drift"):
                verify.load_corpus(root)

    def test_empty_bool_pages_and_cross_split_family_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_corpus(root)
            source, cases, freeze = verify.load_corpus(root)
            second = copy.deepcopy(cases[0])
            second.update(id="holdout", split="holdout")
            (root / "cases.json").write_text(json.dumps(cases + [second]))
            freeze["files_sha256"]["cases.json"] = verify.sha(root / "cases.json")
            (root / "freeze.json").write_text(json.dumps(freeze))
            with self.assertRaisesRegex(ValueError, "crosses frozen splits"):
                verify.load_corpus(root)
            cases[0]["pages"] = [True, 4]
            (root / "cases.json").write_text(json.dumps(cases))
            freeze["files_sha256"]["cases.json"] = verify.sha(root / "cases.json")
            (root / "freeze.json").write_text(json.dumps(freeze))
            with self.assertRaisesRegex(ValueError, "page selection"):
                verify.load_corpus(root)

    def test_issuer_and_template_are_independently_disjoint(self):
        for field in ("issuer", "template_family"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.make_corpus(root)
                sources, cases, freeze = verify.load_corpus(root)
                second_source = dict(sources[0], id="second", filename="second.pdf")
                other = "template_family" if field == "issuer" else "issuer"
                second_source[other] = "different"
                second_case = copy.deepcopy(cases[0])
                second_case.update(id="holdout", source_id="second", split="holdout")
                (root / "sources.json").write_text(json.dumps(sources + [second_source]))
                (root / "cases.json").write_text(json.dumps(cases + [second_case]))
                freeze["files_sha256"] = {name: verify.sha(root / name) for name in ("sources.json", "cases.json")}
                (root / "freeze.json").write_text(json.dumps(freeze))
                with self.assertRaisesRegex(ValueError, "crosses frozen splits"):
                    verify.load_corpus(root)

    def test_bounded_command_retains_timeout_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = verify.run_command([sys.executable, "-u", "-c", "import time; print('kept'); time.sleep(5)"], root / "out", root / "err", 0.1)
            self.assertEqual(result["failure"], "CLI timeout")
            self.assertIn("kept", (root / "out").read_text())

    def test_bounded_command_rejects_output_budget_even_after_exit(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(verify, "MAX_OUTPUT_BYTES", 1024):
            root = Path(directory)
            result = verify.run_command([sys.executable, "-c", "print('x'*2048)"], root / "out", root / "err", 1)
            self.assertEqual(result["failure"], "CLI output budget exceeded")
            self.assertGreater((root / "out").stat().st_size, 1024)


class OwnedGroupTests(unittest.TestCase):
    def writer_command(self, root, normal_exit=False):
        ready = root / "descendant.pid"
        child = ("import os, signal, time\nfrom pathlib import Path\n"
                 "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                 f"Path({str(ready)!r}).write_text(str(os.getpid()))\n"
                 "while True:\n os.write(1, b'retained evidence\\n')\n time.sleep(0.01)\n")
        leader = ("import subprocess, sys, time\nfrom pathlib import Path\n"
                  f"subprocess.Popen([sys.executable, '-u', '-c', {child!r}])\n"
                  f"while not Path({str(ready)!r}).exists(): time.sleep(0.005)\n"
                  + ("sys.exit(0)\n" if normal_exit else "time.sleep(10)\n"))
        return [sys.executable, "-u", "-c", leader], ready

    def assert_receipt_stable_and_child_stopped(self, stdout, ready):
        self.assertTrue(ready.is_file(), "descendant must start before this regression is exercised")
        before = stdout.stat().st_size
        time.sleep(0.15)
        self.assertEqual(stdout.stat().st_size, before, "owned descendant kept writing after run_command returned")
        state = subprocess.run(["ps", "-p", ready.read_text(), "-o", "stat="], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), f"owned descendant is still active: {state}")

    def cleanup_if_active(self, ready):
        # Clean up only a live child created by this regression if it failed.
        if ready.is_file():
            child_pid = int(ready.read_text())
            state = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
            if state and not state.startswith("Z"):
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_timeout_finalizes_term_ignoring_descendant_after_leader_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command, ready = self.writer_command(root)
            try:
                result = verify.run_command(command, root / "stdout", root / "stderr", 0.3)
                self.assertEqual(result["failure"], "CLI timeout")
                self.assert_receipt_stable_and_child_stopped(root / "stdout", ready)
            finally:
                self.cleanup_if_active(ready)

    def test_normal_leader_exit_finalizes_term_ignoring_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command, ready = self.writer_command(root, normal_exit=True)
            try:
                result = verify.run_command(command, root / "stdout", root / "stderr", 2)
                self.assertEqual(result["exit_code"], 0)
                self.assertIsNone(result["failure"])
                self.assert_receipt_stable_and_child_stopped(root / "stdout", ready)
            finally:
                self.cleanup_if_active(ready)

    def test_output_breach_finalizes_term_ignoring_descendant(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(verify, "MAX_OUTPUT_BYTES", 64):
            root = Path(directory)
            command, ready = self.writer_command(root)
            try:
                result = verify.run_command(command, root / "stdout", root / "stderr", 2)
                self.assertEqual(result["failure"], "CLI output budget exceeded")
                self.assert_receipt_stable_and_child_stopped(root / "stdout", ready)
            finally:
                self.cleanup_if_active(ready)

    def test_monitor_exception_and_interrupt_finalize_owned_group(self):
        real_sleep = time.sleep
        for exception in (OSError, KeyboardInterrupt):
            with self.subTest(exception=exception.__name__), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                command, ready = self.writer_command(root)
                raised = False

                def fail_after_child_ready(seconds):
                    nonlocal raised
                    if ready.exists() and not raised:
                        raised = True
                        raise exception("injected monitor interruption")
                    real_sleep(seconds)

                try:
                    with mock.patch.object(verify.time, "sleep", side_effect=fail_after_child_ready), self.assertRaises(exception):
                        verify.run_command(command, root / "stdout", root / "stderr", 2)
                    self.assert_receipt_stable_and_child_stopped(root / "stdout", ready)
                finally:
                    self.cleanup_if_active(ready)

    def test_interrupt_during_term_grace_still_sends_kill(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command, ready = self.writer_command(root, normal_exit=True)
            real_sleep = time.sleep

            def interrupt_grace(seconds):
                if seconds == 0.2:
                    raise KeyboardInterrupt("injected grace interruption")
                real_sleep(seconds)

            try:
                with mock.patch.object(verify.time, "sleep", side_effect=interrupt_grace), self.assertRaises(KeyboardInterrupt):
                    verify.run_command(command, root / "stdout", root / "stderr", 2)
                self.assert_receipt_stable_and_child_stopped(root / "stdout", ready)
            finally:
                self.cleanup_if_active(ready)


if __name__ == "__main__":
    unittest.main()
