import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("topology_verifier", Path(__file__).with_name("verify.py"))
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)


def cell(text="Cash", column=0, rowspan=1, colspan=1, ids=None):
    return dict(text=text,row=0,column=column,rowspan=rowspan,colspan=colspan,page_index=0,
                source_span_ids=["span-0"] if ids is None else ids)


class TopologyTests(unittest.TestCase):
    def test_public_command_uses_supported_ocr_disable_flag(self):
        command = verify.extraction_command("parser", "input.pdf", "artifact-jsonl")
        self.assertIn("--no-ocr", command)
        self.assertNotIn("--disable-ocr", command)

    def test_boundary_count_uses_exact_financial_tokens(self):
        values=["Cash","0","(640)"]
        cells=[cell(text,column=i,ids=[f"span-{i}"]) for i,text in enumerate(values)]
        records=[dict(record_type="document_manifest",page_count=1)]
        records += [dict(record_type="span",span_id=f"span-{i}",text=text,page_index=0) for i,text in enumerate(values)]
        records += [dict(record_type="table",column_count=3,rows=[dict(cells=cells)])]
        truth=[dict(rows=[dict(cells=cells)])]
        self.assertEqual("verified",verify.score(records,truth,"boundary-ownership")["status"])
        records[-1]["rows"][0]["cells"] = cells + [cell("0",column=3,ids=["span-3"])]
        records.insert(1,dict(record_type="span",span_id="span-3",text="0",page_index=0))
        self.assertIn("crossing text duplicated or missing: 0",verify.score(records,truth,"boundary-ownership")["failures"])

    def test_declared_empty_row_changes_physical_topology(self):
        rows=[dict(cells=[cell(),cell("0",column=1)])]
        truth=[dict(topology_required=True,column_count=2,rows=rows)]
        actual=[dict(column_count=2,rows=rows+[dict(row_index=1,cells=[])])]
        self.assertEqual(0.0,verify.topology_accuracy(actual,truth))

    def test_declared_grid_extent_is_scored(self):
        rows=[dict(cells=[cell(),cell("0",column=1)])]
        truth=[dict(topology_required=True,column_count=2,rows=rows)]
        self.assertEqual(0.0,verify.topology_accuracy([dict(column_count=3,rows=rows)],truth))
        self.assertEqual(1.0,verify.topology_accuracy([dict(column_count=2,rows=rows)],truth))
        self.assertEqual(1.0,verify.topology_accuracy([dict(rows=rows)],truth))

    def test_flattened_text_does_not_hide_wrong_span(self):
        actual=[dict(column_count=2,rows=[dict(cells=[cell(colspan=2)])])]
        truth=[dict(topology_required=True,column_count=2,rows=[dict(cells=[cell()])])]
        self.assertEqual(0.0, verify.topology_accuracy(actual,truth))

    def test_merged_placeholder_is_not_an_overlap(self):
        table=dict(column_count=2,rows=[dict(cells=[cell(colspan=2),cell("",column=1)])])
        self.assertEqual([(0,0,1,2)],verify.table_topology(table))
        table["rows"][0]["cells"][1]["text"]="unexpected"
        self.assertIsNone(verify.table_topology(table))

    def test_uncovered_blank_is_a_real_slot(self):
        table=dict(column_count=2,rows=[dict(cells=[cell(),cell("",column=1)])])
        self.assertEqual([(0,0,1,1),(0,1,1,1)],verify.table_topology(table))

    def test_malformed_or_oversized_spans_are_rejected(self):
        for value in [True,0,-1,10**12]:
            table=dict(column_count=2,rows=[dict(cells=[cell(colspan=value)])])
            self.assertIsNone(verify.table_topology(table))

    def test_nonempty_source_claim_must_match_text(self):
        records=[dict(record_type="document_manifest"),dict(record_type="span",span_id="span-0",text="Other",page_index=0),
                 dict(record_type="table",column_count=1,rows=[dict(cells=[cell()])])]
        truth=[dict(topology_required=True,column_count=1,rows=[dict(cells=[cell()])])]
        self.assertIn("source text disagrees with cell text",verify.score(records,truth,"regular")["failures"])

    def test_empty_cell_cannot_claim_row_evidence(self):
        records=[dict(record_type="document_manifest"),dict(record_type="span",span_id="span-0",text="Cash",page_index=0),
                 dict(record_type="table",column_count=1,rows=[dict(cells=[cell("")])])]
        truth=[dict(topology_required=True,column_count=1,rows=[dict(cells=[cell("")])])]
        self.assertIn("empty cell claims source text",verify.score(records,truth,"regular")["failures"])

    def test_duplicate_source_ownership_is_rejected(self):
        cells=[cell(),cell(column=1)]
        records=[dict(record_type="document_manifest"),dict(record_type="span",span_id="span-0",text="Cash",page_index=0),
                 dict(record_type="table",column_count=2,rows=[dict(cells=cells)])]
        truth=[dict(topology_required=True,column_count=2,rows=[dict(cells=cells)])]
        self.assertIn("source span has multiple cell owners",verify.score(records,truth,"regular")["failures"])

    def test_negative_control_fails_on_invented_table(self):
        records=[dict(record_type="document_manifest"),dict(record_type="table",rows=[])]
        self.assertEqual("failed",verify.score(records,[],"negative")["status"])

    def test_incomplete_or_misordered_stream_is_rejected(self):
        records=[dict(record_type="document_manifest"),dict(record_type="document_finished",status="completed")]
        self.assertEqual("failed",verify.score(records,[],"negative","stream-jsonl")["status"])

    def test_stream_page_identity_and_completion_count_are_checked(self):
        records=[dict(record_type="document_manifest",page_count=1),
                 dict(record_type="page_started",page_index=0,status="running"),
                 dict(record_type="page_finished",page_index=0,status="completed"),
                 dict(record_type="document_finished",status="completed")]
        self.assertEqual("verified",verify.score(records,[],"negative","stream-jsonl")["status"])
        records[2]["page_index"]=99
        self.assertEqual("failed",verify.score(records,[],"negative","stream-jsonl")["status"])
        records[2]["page_index"]=0
        records[0]["page_count"]=2
        self.assertEqual("failed",verify.score(records,[],"negative","stream-jsonl")["status"])

    def test_stream_artifact_cannot_claim_another_page(self):
        records=[dict(record_type="document_manifest",page_count=1),
                 dict(record_type="page_started",page_index=0,status="running"),
                 dict(record_type="span",span_id="span-0",text="outside",page_index=9),
                 dict(record_type="page_finished",page_index=0,status="completed"),
                 dict(record_type="document_finished",status="completed")]
        self.assertIn("artifact outside page lifecycle",verify.score(records,[],"negative","stream-jsonl")["failures"])


if __name__ == "__main__":
    unittest.main()
