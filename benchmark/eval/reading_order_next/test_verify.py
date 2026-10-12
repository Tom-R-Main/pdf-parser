import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("order_next_verify", Path(__file__).with_name("verify.py"))
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def truth():
    return dict(nodes=[dict(id="a", text_anchor="Anchor Alpha", page_index=0),
                       dict(id="b", text_anchor="Anchor Beta", page_index=0),
                       dict(id="c", text_anchor="Anchor Gamma", page_index=1)],
                page_local_precedence=[["a", "b"]], document_precedence=[["b", "c"]])


def records():
    result = [dict(record_type="document_manifest", page_count=2)]
    for page, anchors in ((0, ["Anchor Alpha", "Anchor Beta"]), (1, ["Anchor Gamma"])):
        result.append(dict(record_type="page_started", page_index=page, status="running"))
        for kind in ("span", "block"):
            result.extend(dict(record_type=kind, page_index=page, text=anchor) for anchor in anchors)
        result.append(dict(record_type="page_finished", page_index=page, status="completed"))
    result.append(dict(record_type="document_finished", status="completed"))
    return result


class VerificationTest(unittest.TestCase):
    def test_valid_stream_and_artifact(self):
        self.assertEqual(VERIFY.score_records(records(), truth(), "stream-jsonl")["verdict"], "verified")
        artifact = [r for r in records() if r["record_type"] in ("span", "block", "document_manifest")]
        self.assertEqual(VERIFY.score_records(artifact, truth(), "artifact-jsonl")["verdict"], "verified")

    def test_inversion_inside_one_block(self):
        source = [dict(record_type="document_manifest", page_count=2),
                  dict(record_type="span", page_index=0, text="Anchor Alpha Anchor Beta"),
                  dict(record_type="span", page_index=1, text="Anchor Gamma"),
                  dict(record_type="block", page_index=0, text="Anchor Beta Anchor Alpha"),
                  dict(record_type="block", page_index=1, text="Anchor Gamma")]
        result = VERIFY.score_records(source, truth(), "artifact-jsonl")
        self.assertEqual(result["emitted_page_local"]["passed"], 0)
        self.assertEqual(result["emitted_document"]["passed"], 1)
        self.assertEqual(result["verdict"], "failed")

    def test_missing_duplicate_and_wrong_page(self):
        for replacement in ("", "Anchor Alpha Anchor Alpha", "Anchor Beta"):
            source = records()
            next(r for r in source if r["record_type"] == "span")["text"] = replacement
            self.assertEqual(VERIFY.score_records(source, truth(), "stream-jsonl")["verdict"], "failed")
        source = records()
        next(r for r in source if r["record_type"] == "span")["page_index"] = 1
        self.assertEqual(VERIFY.score_records(source, truth(), "stream-jsonl")["verdict"], "failed")

    def test_cross_page_order_separate_from_local(self):
        source = [dict(record_type="document_manifest", page_count=2)]
        for kind in ("span", "block"):
            source.extend([dict(record_type=kind, page_index=1, text="Anchor Gamma"),
                           dict(record_type=kind, page_index=0, text="Anchor Alpha"),
                           dict(record_type=kind, page_index=0, text="Anchor Beta")])
        result = VERIFY.score_records(source, truth(), "artifact-jsonl")
        self.assertEqual(result["emitted_page_local"]["passed"], 1)
        self.assertEqual(result["emitted_document"]["passed"], 0)
        self.assertIn("not inferred", result["graph_diagnostics"])

    def test_lifecycle_and_cli_errors(self):
        variants = [records()[:-1], records()[1:], records() + [dict(record_type="block", text="late", page_index=1)]]
        incomplete = records()
        incomplete[1]["status"] = "completed"
        variants.append(incomplete)
        error = records()
        error[-1]["errors"] = ["failed extraction"]
        variants.append(error)
        for source in variants:
            self.assertEqual(VERIFY.score_records(source, truth(), "stream-jsonl")["verdict"], "failed")
        self.assertEqual(VERIFY.score_records(records(), truth(), "stream-jsonl", 7)["verdict"], "failed")

    def test_malformed_jsonl(self):
        for source in (b"not json\n", b"[]\n", b'{"text":"missing record type"}\n',
                       b'{"record_type":"span","text":null,"page_index":0}\n'):
            with self.assertRaises(ValueError):
                VERIFY.parse_records(source)

    def test_diagnostic_failures_are_separate_and_visible(self):
        row = dict(doc_id="example", metrics=dict(reading_graph_required_recall=0.0,
                   reading_graph_valid_projection=1.0, reading_graph_cycle_rate=0.0))
        result = VERIFY.score_diagnostic([row], "example")
        self.assertEqual(result["verdict"], "failed")
        self.assertEqual(len(result["failures"]), 1)
        row["metrics"]["reading_graph_required_recall"] = 1.0
        self.assertEqual(VERIFY.score_diagnostic([row], "example")["verdict"], "verified")
        self.assertEqual(VERIFY.score_diagnostic([row], "other")["verdict"], "failed")
        self.assertEqual(VERIFY.score_diagnostic([], "example")["verdict"], "failed")

    def test_failed_cli_evidence_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            stem = Path(directory) / "failure"
            code, output = VERIFY.execute(["/usr/bin/false"], stem, 2)
            self.assertNotEqual(code, 0)
            self.assertEqual(output, b"")
            self.assertTrue(stem.with_suffix(".stdout.jsonl").is_file())
            self.assertTrue(stem.with_suffix(".stderr.txt").is_file())

    def test_whitespace_and_anchor_boundaries(self):
        self.assertEqual(len(VERIFY.occurrences("Anchor   Alpha\nAnchor Alpha", "Anchor Alpha")), 2)
        self.assertEqual(VERIFY.occurrences("Anchor Alphabet", "Anchor Alpha"), [])


if __name__ == "__main__":
    unittest.main()
