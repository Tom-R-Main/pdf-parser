import copy
import importlib.util
from pathlib import Path
import unittest


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


verify = module("region_verifier_test","verify.py")
generate = module("region_generator_test","generate.py")
SOURCE = "test-drawing"
HASH = "a"*64


def envelope(kind, bbox=None, **fields):
    result = dict(record_type=kind,schema_name=kind,schema_version="0.19.2",source_id=SOURCE,
                  document_id="test-document",provenance=dict(source_id=SOURCE,document_id="test-document",
                  input_sha256=HASH,page_index=fields.get("page_index"),bbox=bbox))
    if bbox is not None:
        result["bbox"] = bbox
    result.update(fields)
    return result


def valid_records(truth, fmt="artifact-jsonl"):
    artifacts = []
    for ti,expected in enumerate(truth["tables"]):
        region = expected["region"]
        nc,nr = expected["column_count"],len(expected["rows"])
        width = (region["x1"]-region["x0"])/nc
        height = (region["y1"]-region["y0"])/nr
        rows = []
        for ri,expected_row in enumerate(expected["rows"]):
            row_box = dict(x0=region["x0"],x1=region["x1"],y0=region["y1"]-(ri+1)*height,y1=region["y1"]-ri*height)
            bid = f"block-{ti}-{ri}"
            artifacts.append(envelope("block",copy.deepcopy(row_box),page_index=0,block_id=bid,
                                      text=" ".join(c["text"] for c in expected_row["cells"])))
            cells = []
            for ci,c in enumerate(expected_row["cells"]):
                cell_box = dict(x0=region["x0"]+ci*width,x1=region["x0"]+(ci+1)*width,y0=row_box["y0"],y1=row_box["y1"])
                sid = f"span-{ti}-{ri}-{ci}"
                ids = [sid] if c["text"] else []
                bids = [bid] if c["text"] else []
                if ids:
                    span = envelope("span",copy.deepcopy(cell_box),page_index=0,span_id=sid,text=c["text"],reconciled_block_id=bid)
                    span["provenance"]["block_ids"] = [bid]
                    artifacts.append(span)
                cell = envelope("table_cell",copy.deepcopy(cell_box),**c,page_index=0,cell_id=f"cell-{ti}-{ri}-{ci}",source_span_ids=ids,reconciled_block_ids=bids)
                cell["provenance"]["span_ids"] = ids.copy()
                cell["provenance"]["block_ids"] = bids.copy()
                cells.append(cell)
            rows.append(dict(row_index=ri,bbox=row_box,cells=cells))
        ids = [sid for row in rows for cell in row["cells"] for sid in cell["source_span_ids"]]
        bids = sorted({bid for row in rows for cell in row["cells"] for bid in cell["reconciled_block_ids"]})
        record = envelope("table",copy.deepcopy(region),page_index=0,table_id=f"table-{ti}",column_count=nc,rows=rows,
                          source_span_ids=ids,reconciled_block_ids=bids,block_index=ti*10,block_count=1)
        record["provenance"].update(span_ids=ids.copy(),block_ids=[f"block-{ti*10}"])
        artifacts.append(record)
    for i,prose in enumerate(truth["retained_prose"]):
        span = envelope("span",copy.deepcopy(prose["region"]),page_index=0,span_id=f"prose-{i}",text=prose["text"],reconciled_block_id=f"prose-block-{i}")
        span["provenance"]["block_ids"] = [f"prose-block-{i}"]
        artifacts.append(span)
        artifacts.append(envelope("block",copy.deepcopy(prose["region"]),page_index=0,block_id=f"prose-block-{i}",text=prose["text"]))
    ordered_spans = [r for r in artifacts if r["record_type"] == "span"]
    for block in (r for r in artifacts if r["record_type"] == "block"):
        indices = [i for i,r in enumerate(ordered_spans) if r["reconciled_block_id"] == block["block_id"]]
        ids = [ordered_spans[i]["span_id"] for i in indices]
        block["span_start"] = indices[0] if indices else 0
        block["span_count"] = len(indices)
        block["provenance"]["span_ids"] = ids.copy()
    manifest = envelope("document_manifest",page_count=1,input_sha256=HASH)
    if fmt == "stream-jsonl":
        return [manifest,envelope("page_started",page_index=0,status="running"),*artifacts,
                envelope("page_finished",page_index=0,status="completed"),envelope("document_finished",status="completed")]
    return [manifest,*artifacts]


class RegionVerifierTests(unittest.TestCase):
    def setUp(self):
        self.truth = list(generate.cases())[0][2]
        self.records = valid_records(self.truth)

    def score(self,records=None,truth=None,fmt="artifact-jsonl"):
        return verify.score(self.records if records is None else records,self.truth if truth is None else truth,SOURCE,HASH,fmt)

    def fail(self,label,records=None):
        result = self.score(records)
        self.assertEqual(result["status"],"failed")
        self.assertTrue(any(label in f for f in result["failures"]),result["failures"])

    def first_table(self):
        return next(r for r in self.records if r["record_type"] == "table")

    def test_drawing_inventory_freeze_and_both_valid_formats(self):
        cases,freeze = verify.load_corpus()
        self.assertEqual(len(cases),8)
        self.assertEqual(len(freeze["files_sha256"]),18)
        for name,data,truth in generate.cases():
            self.assertTrue(data.startswith(b"%PDF-1.4"),name)
            for fmt in ("artifact-jsonl","stream-jsonl"):
                result = self.score(valid_records(truth,fmt),truth,fmt)
                self.assertEqual("verified",result["status"],(name,result["failures"]))

    def test_command_uses_supported_ocr_flag_and_source_identity(self):
        command = verify.extraction_command("parser","input.pdf",SOURCE,"artifact-jsonl")
        self.assertIn("--no-ocr",command)
        self.assertNotIn("--disable-ocr",command)
        self.assertEqual(command[command.index("--source-id")+1],SOURCE)

    def test_wrong_count(self):
        self.records.remove(self.first_table())
        self.fail("table count")

    def test_wrong_region(self):
        self.first_table()["bbox"] = dict(x0=0,y0=0,x1=40,y1=40)
        self.fail("bounded expected region")

    def test_tiny_fragment_cannot_pass_region_coverage(self):
        self.first_table()["bbox"] = dict(x0=54,y0=548,x1=70,y1=560)
        self.fail("region coverage")

    def test_tight_bounds_can_pass_without_exact_drawing_edges(self):
        region = self.truth["tables"][0]["region"]
        tight = {k:v+8 if k in ("x0","y0") else v-8 for k,v in region.items()}
        precision,coverage = verify.region_coverage(tight,region)
        self.assertEqual(precision,1)
        self.assertGreater(coverage,0.45)
        self.assertTrue(verify.within(tight,region,6))

    def test_missing_prose_even_if_block_survives(self):
        self.records = [r for r in self.records if r.get("span_id") != "prose-0"]
        self.fail("retained prose")

    def test_wrong_prose_location(self):
        prose = next(r for r in self.records if r.get("span_id") == "prose-0")
        prose["bbox"] = dict(x0=0,y0=0,x1=40,y1=40)
        self.fail("retained prose")

    def test_prose_cannot_be_consumed_by_a_cell(self):
        cell = self.first_table()["rows"][0]["cells"][0]
        cell["source_span_ids"].append("prose-0")
        self.fail("prose outside source ownership")

    def test_duplicate_prose_is_not_full_retention(self):
        prose = copy.deepcopy(next(r for r in self.records if r.get("span_id") == "prose-0"))
        prose["span_id"] = "prose-copy"
        self.records.append(prose)
        self.fail("retained prose")

    def test_duplicate_table_text_outside_all_truth_regions(self):
        duplicate = copy.deepcopy(next(r for r in self.records if r["record_type"] == "span"))
        duplicate["span_id"] = "unclaimed-copy"
        duplicate["bbox"] = dict(x0=5,y0=5,x1=50,y1=20)
        duplicate["provenance"]["bbox"] = duplicate["bbox"].copy()
        self.records.append(duplicate)
        self.fail("complete source token inventory")

    def test_missing_unclaimed_source_is_inventory_failure(self):
        truth = list(generate.cases())[4][2]
        records = valid_records(truth)
        records = [r for r in records if r.get("span_id") != "prose-2"]
        result = self.score(records,truth)
        self.assertIn("complete source token inventory",result["failures"])

    def test_table_aggregate_source_ids_cannot_hide_extra_claim(self):
        self.first_table()["source_span_ids"].append("prose-0")
        self.fail("exact aggregate source spans")

    def test_table_aggregate_source_ids_cannot_omit_cell_source(self):
        self.first_table()["source_span_ids"].pop()
        self.fail("exact aggregate source spans")

    def test_table_provenance_cannot_claim_unrelated_block(self):
        self.first_table()["provenance"]["block_ids"].append("prose-block-0")
        self.fail("table provenance legacy layout blocks")

    def test_table_legacy_layout_namespace_is_distinct(self):
        self.assertNotEqual(self.first_table()["provenance"]["block_ids"],self.first_table()["reconciled_block_ids"])
        self.assertEqual(self.score()["status"],"verified")
        self.first_table()["block_count"] = True
        self.fail("bounded legacy layout interval")

    def test_span_provenance_owner_must_match_live_convenience_owner(self):
        span = next(r for r in self.records if r["record_type"] == "span")
        span["reconciled_block_id"] = "prose-block-0"
        self.fail("span provenance owner")

    def test_wrong_live_block_with_mutated_convenience_and_provenance_fails_reverse_membership(self):
        span = next(r for r in self.records if r["record_type"] == "span")
        span["reconciled_block_id"] = "prose-block-0"
        span["provenance"]["block_ids"] = ["prose-block-0"]
        cell = self.first_table()["rows"][0]["cells"][0]
        cell["reconciled_block_ids"] = ["prose-block-0"]
        cell["provenance"]["block_ids"] = ["prose-block-0"]
        self.fail("reciprocal block span membership")

    def test_block_provenance_membership_cannot_omit_source(self):
        block = next(r for r in self.records if r["record_type"] == "block")
        block["provenance"]["span_ids"].pop()
        self.fail("block provenance source spans")

    def test_actual_block_schema_uses_span_interval_without_table_convenience_field(self):
        block = next(r for r in self.records if r["record_type"] == "block")
        self.assertNotIn("source_span_ids",block)
        self.assertEqual(self.score()["status"],"verified")
        block["span_start"] += 1
        self.fail("block provenance source spans")

    def test_malformed_block_span_interval(self):
        block = next(r for r in self.records if r["record_type"] == "block")
        block["span_count"] = True
        self.fail("bounded block span interval")

    def test_cell_provenance_owning_blocks_must_match(self):
        self.first_table()["rows"][0]["cells"][0]["provenance"]["block_ids"] = ["prose-block-0"]
        self.fail("cell provenance owning blocks")

    def test_cell_and_source_cannot_move_into_next_row_preserving_slot(self):
        cell = self.first_table()["rows"][0]["cells"][0]
        sid = cell["source_span_ids"][0]
        span = next(r for r in self.records if r.get("span_id") == sid)
        for record in (cell,span):
            for key in ("y0","y1"):
                record["bbox"][key] -= 44
            record["provenance"]["bbox"] = record["bbox"].copy()
        self.assertEqual(cell["row"],0)
        self.fail("nonblank cell within physical row")
        self.fail("source within physical row")

    def test_table_aggregate_blocks_must_be_live_exact_owners(self):
        self.first_table()["reconciled_block_ids"].append("block-1-0")
        self.fail("exact aggregate owning blocks")

    def test_duplicate_source_owner(self):
        cells = self.first_table()["rows"][0]["cells"]
        cells[1]["source_span_ids"] = cells[0]["source_span_ids"].copy()
        self.fail("exclusive source owner")

    def test_blank_claims_no_sources(self):
        cells = self.first_table()["rows"][2]["cells"]
        cells[2]["source_span_ids"] = cells[0]["source_span_ids"].copy()
        self.fail("blank claims no source")

    def test_blank_is_not_zero(self):
        self.first_table()["rows"][2]["cells"][1]["text"] = ""
        self.fail("exact cell text including blank zero dash")

    def test_physical_slot_and_occupancy(self):
        self.first_table()["rows"][0]["cells"][0]["colspan"] = 2
        self.fail("exact topology")

    def test_false_integer_slot(self):
        self.first_table()["rows"][0]["cells"][0]["column"] = True
        self.fail("physical cell slots")

    def test_malformed_bbox(self):
        for malformed in ([54,548,530,724],dict(x0=True,y0=548,x1=530,y1=724),
                          dict(x0=54,y0=548,x1=float("nan"),y1=724),dict(x0=54,y0=548,x1=float("inf"),y1=724),
                          dict(x0=540,y0=548,x1=530,y1=724)):
            records = copy.deepcopy(self.records)
            next(r for r in records if r["record_type"] == "table")["bbox"] = malformed
            self.fail("finite object bbox",records)

    def test_malformed_nested_geometry(self):
        self.first_table()["rows"][0]["bbox"] = [54,680,530,724]
        self.fail("finite row bbox")
        self.first_table()["rows"][0]["cells"][0]["bbox"] = None
        self.fail("finite cell bbox")

    def test_overlapping_regions_rejected(self):
        tables = [r for r in self.records if r["record_type"] == "table"]
        tables[1]["bbox"] = copy.deepcopy(tables[0]["bbox"])
        self.fail("separate table regions")

    def test_duplicate_span_identity(self):
        self.records.append(copy.deepcopy(next(r for r in self.records if r["record_type"] == "span")))
        self.fail("unique span identity")

    def test_dangling_block_reference(self):
        self.records = [r for r in self.records if r.get("block_id") != "block-0-0"]
        self.fail("live source block")

    def test_extraneous_block_reference(self):
        self.first_table()["rows"][0]["cells"][0]["reconciled_block_ids"].append("block-0-1")
        self.fail("exact owning blocks")

    def test_source_hash_mismatch(self):
        self.records[0]["input_sha256"] = "b"*64
        self.fail("manifest input hash")

    def test_source_identity_mismatch(self):
        self.records[1]["source_id"] = "wrong-drawing"
        self.fail("source identity")

    def test_wrong_page_rejected(self):
        span = next(r for r in self.records if r["record_type"] == "span")
        span["page_index"] = 1
        self.fail("page zero")

    def test_batch_cannot_include_stream_lifecycle(self):
        self.records.insert(1,envelope("page_started",page_index=0,status="running"))
        self.fail("no stream lifecycle")

    def test_stream_lifecycle_missing_finish(self):
        records = valid_records(self.truth,"stream-jsonl")[:-1]
        result = self.score(records,fmt="stream-jsonl")
        self.assertIn("complete stream",result["failures"])

    def test_stream_artifact_after_page_finish(self):
        records = valid_records(self.truth,"stream-jsonl")
        records.insert(-1,records.pop(2))
        result = self.score(records,fmt="stream-jsonl")
        self.assertTrue(any("active artifact" in f for f in result["failures"]))

    def test_extra_empty_row_rejected(self):
        self.first_table()["rows"].append(dict(row_index=4,bbox=dict(x0=54,y0=530,x1=530,y1=548),cells=[]))
        self.fail("row extent")

    def test_nonobjects_fail_closed(self):
        self.assertEqual(self.score([None])["failures"],["JSONL records are objects"])


if __name__ == "__main__":
    unittest.main()
