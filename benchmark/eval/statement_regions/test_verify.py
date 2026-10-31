import copy
import importlib.util
from pathlib import Path
import unittest


def module(name,path):
    spec = importlib.util.spec_from_file_location(name,path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


ROOT = Path(__file__).resolve().parent
verify = module("statement_verifier_test",ROOT/"verify.py")
generate = module("statement_generator_test",ROOT/"generate.py")
factory = module("statement_public_record_factory",ROOT.parent/"table_regions"/"test_verify.py")


def score(records,truth,fmt="artifact-jsonl"):
    name = next(name for name,pdf,drawing_truth in generate.cases() if drawing_truth == truth)
    return verify.score(records,truth,name,factory.HASH,fmt)


def valid_records(truth,fmt="artifact-jsonl"):
    name = next(name for name,pdf,drawing_truth in generate.cases() if drawing_truth == truth)
    records = factory.valid_records(truth,fmt)
    def source_identity(value):
        if isinstance(value,dict):
            if "source_id" in value:
                value["source_id"] = name
            for item in value.values():
                source_identity(item)
        elif isinstance(value,list):
            for item in value:
                source_identity(item)
    source_identity(records)
    geometry = next(c for c in verify.load_geometry()["cases"] if c["id"] == name)
    tables = [r for r in records if r["record_type"] == "table"]
    spans = {r["span_id"]:r for r in records if r["record_type"] == "span"}
    blocks = {r["block_id"]:r for r in records if r["record_type"] == "block"}
    for table,expected in zip(tables,geometry["tables"]):
        for row,frozen_row in zip(table["rows"],expected["rows"]):
            for key in ("y0","y1"):
                row["bbox"][key] = frozen_row["region"][key]
            for cell in row["cells"]:
                for key in ("y0","y1"):
                    cell["bbox"][key] = frozen_row["region"][key]
                cell["provenance"]["bbox"] = cell["bbox"].copy()
                for sid in cell["source_span_ids"]:
                    span = spans[sid]
                    span["bbox"] = cell["bbox"].copy()
                    span["provenance"]["bbox"] = span["bbox"].copy()
                    block = blocks[span["reconciled_block_id"]]
                    block["bbox"] = row["bbox"].copy()
                    block["provenance"]["bbox"] = block["bbox"].copy()
    return records


def split_label(records,ri,parts):
    table = next(r for r in records if r["record_type"] == "table")
    cell = table["rows"][ri]["cells"][0]
    sid = cell["source_span_ids"][0]
    index = next(i for i,r in enumerate(records) if r.get("span_id") == sid)
    original = records[index]
    fragments = []
    mid = (original["bbox"]["y0"]+original["bbox"]["y1"])/2
    for i,part in enumerate(parts):
        span = copy.deepcopy(original)
        span["span_id"] = sid+"-part-"+str(i)
        span["text"] = part
        if i == 0:
            span["bbox"]["y0"] = mid
        else:
            span["bbox"]["y1"] = mid
        span["provenance"]["bbox"] = span["bbox"].copy()
        fragments.append(span)
    records[index:index+1] = fragments
    cell["source_span_ids"] = [r["span_id"] for r in fragments]
    cell["provenance"]["span_ids"] = cell["source_span_ids"].copy()
    table["source_span_ids"] = [sid for row in table["rows"] for c in row["cells"] for sid in c["source_span_ids"]]
    table["provenance"]["span_ids"] = table["source_span_ids"].copy()
    ordered = [r for r in records if r["record_type"] == "span"]
    for block in (r for r in records if r["record_type"] == "block"):
        indices = [i for i,r in enumerate(ordered) if r["reconciled_block_id"] == block["block_id"]]
        block["span_start"],block["span_count"] = (indices[0] if indices else 0),len(indices)
        block["provenance"]["span_ids"] = [ordered[i]["span_id"] for i in indices]
    return cell,fragments


class StatementContractTests(unittest.TestCase):
    def test_new_freeze_and_all_eight_exact_shapes_both_formats(self):
        cases,freeze = verify.load_corpus()
        self.assertEqual(len(cases),8)
        self.assertEqual(len(freeze["files_sha256"]),18)
        self.assertEqual(len(freeze["dependencies_sha256"]),1)
        for name,pdf,truth in generate.cases():
            self.assertTrue(pdf.startswith(b"%PDF-1.4"))
            for fmt in ("artifact-jsonl","stream-jsonl"):
                result = score(valid_records(truth,fmt),truth,fmt)
                self.assertEqual(result["status"],"verified",(name,result["failures"]))

    def test_two_wrapped_source_fragments_keep_strict_row_and_ownership_contract(self):
        cases = list(generate.cases())
        for index,parts in ((1,["Replacement","filter kits"]),(2,["Portable sample","carriers"])):
            truth = cases[index][2]
            for fmt in ("artifact-jsonl","stream-jsonl"):
                records = valid_records(truth,fmt)
                split_label(records,1,parts)
                result = score(records,truth,fmt)
                self.assertEqual(result["status"],"verified",result["failures"])

    def test_missing_wrapped_fragment_is_not_acceptable_flattened_text(self):
        truth = list(generate.cases())[1][2]
        records = valid_records(truth)
        cell,fragments = split_label(records,1,["Replacement","filter kits"])
        records.remove(fragments[1])
        failures = score(records,truth)["failures"]
        self.assertIn("complete source token inventory",failures)
        self.assertTrue(any("live source reference" in f for f in failures))

    def test_wrapped_fragment_cannot_cross_its_declared_physical_row(self):
        truth = list(generate.cases())[2][2]
        records = valid_records(truth)
        cell,fragments = split_label(records,1,["Portable sample","carriers"])
        for key in ("y0","y1"):
            fragments[1]["bbox"][key] -= 80
        fragments[1]["provenance"]["bbox"] = fragments[1]["bbox"].copy()
        failures = score(records,truth)["failures"]
        self.assertTrue(any("source within physical row" in f for f in failures))

    def test_section_numeric_blanks_cannot_become_zero(self):
        truth = list(generate.cases())[0][2]
        records = valid_records(truth)
        table = next(r for r in records if r["record_type"] == "table")
        table["rows"][1]["cells"][1]["text"] = "0"
        failures = score(records,truth)["failures"]
        self.assertTrue(any("exact cell text including blank zero dash" in f for f in failures))

    def test_sparse_dash_is_not_blank(self):
        truth = list(generate.cases())[3][2]
        records = valid_records(truth)
        table = next(r for r in records if r["record_type"] == "table")
        table["rows"][7]["cells"][1]["text"] = ""
        failures = score(records,truth)["failures"]
        self.assertTrue(any("exact cell text including blank zero dash" in f for f in failures))

    def test_detached_fragment_must_not_be_claimed_as_cell_evidence(self):
        truth = list(generate.cases())[6][2]
        records = valid_records(truth)
        table = next(r for r in records if r["record_type"] == "table")
        table["rows"][-1]["cells"][0]["source_span_ids"].append("prose-0")
        failures = score(records,truth)["failures"]
        self.assertTrue(any("prose outside source ownership" in f for f in failures))

    def test_repeated_header_does_not_allow_table_omission(self):
        truth = list(generate.cases())[5][2]
        records = valid_records(truth)
        table = [r for r in records if r["record_type"] == "table"][1]
        records.remove(table)
        self.assertIn("table count",score(records,truth)["failures"])

    def test_page_prose_negative_requires_every_source_token(self):
        truth = list(generate.cases())[7][2]
        records = valid_records(truth)
        records = [r for r in records if r.get("span_id") != "prose-0"]
        failures = score(records,truth)["failures"]
        self.assertIn("complete source token inventory",failures)
        self.assertTrue(any("retained prose" in f for f in failures))

    def test_scorer_and_runner_are_shared_not_relaxed_forks(self):
        self.assertIs(verify.run_command,verify.shared.run_command)
        command = verify.extraction_command("parser","drawing.pdf","case","stream-jsonl")
        self.assertIn("--no-ocr",command)
        self.assertIn("--source-id",command)

    def test_expanded_emitted_row_cannot_hide_a_cell_and_source_shift(self):
        truth = list(generate.cases())[0][2]
        records = valid_records(truth)
        table = next(r for r in records if r["record_type"] == "table")
        row = table["rows"][2]
        cell = row["cells"][0]
        span = next(r for r in records if r.get("span_id") == cell["source_span_ids"][0])
        for value in (cell,span):
            for key in ("y0","y1"):
                value["bbox"][key] -= 36
            value["provenance"]["bbox"] = value["bbox"].copy()
        row["bbox"]["y0"] -= 36
        block = next(r for r in records if r.get("block_id") == span["reconciled_block_id"])
        block["bbox"] = row["bbox"].copy()
        block["provenance"]["bbox"] = block["bbox"].copy()
        base = verify.shared.score(records,truth,records[0]["source_id"],factory.HASH)
        self.assertEqual(base["status"],"verified",base["failures"])
        self.assertTrue(any("frozen physical row" in f for f in score(records,truth)["failures"]))


if __name__ == "__main__":
    unittest.main()
