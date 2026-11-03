"""Recorded provider input identity controls; real CLI assertions run separately."""

import json
from pathlib import Path
import tempfile
import unittest

from recorded_ocr import ROOT, load_fixture, words

FIXTURE = ROOT / 'benchmark/eval/recorded_ocr/jpx-mac-2026-11-01/fixture.json'


class RecordedOcrTests(unittest.TestCase):
    def test_capture_identity_and_literal_quotes(self):
        fixture = load_fixture(FIXTURE)
        parsed = words(Path(fixture['tsv_path']).read_bytes())
        self.assertEqual(len(parsed), 96)
        self.assertEqual(sum(len(word[11].encode()) for word in parsed), 311)
        self.assertAlmostEqual(sum(float(word[10]) for word in parsed) / 9600, 0.5980580480208334)
        self.assertEqual(fixture['pixels'], [1190, 1975])

    def reject_change(self, change, message):
        fixture = json.loads(FIXTURE.read_text())
        fixture['tsv'] = str(FIXTURE.parent / fixture['tsv'])
        fixture['capture'] = str(FIXTURE.parent / fixture['capture'])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.json'
            change(fixture, Path(directory))
            path.write_text(json.dumps(fixture))
            with self.assertRaisesRegex(ValueError, message):
                load_fixture(path)

    def test_corrupt_tsv_rejected(self):
        def corrupt(fixture, directory):
            path = directory / 'corrupt.tsv'
            path.write_bytes(Path(fixture['tsv']).read_bytes() + b'corrupt')
            fixture['tsv'] = str(path)
        self.reject_change(corrupt, 'recorded TSV hash mismatch')

    def test_wrong_pdf_rejected(self):
        self.reject_change(lambda fixture, _: fixture.update(pdf_sha256='0' * 64), 'input PDF hash mismatch')

    def test_wrong_geometry_rejected(self):
        self.reject_change(lambda fixture, _: fixture.update(pixels=[100, 100]), 'capture provenance does not match')

    def test_wrong_capture_identity_rejected(self):
        self.reject_change(lambda fixture, _: fixture.update(capture_sha256='0' * 64), 'capture provenance hash mismatch')


if __name__ == '__main__':
    unittest.main()
