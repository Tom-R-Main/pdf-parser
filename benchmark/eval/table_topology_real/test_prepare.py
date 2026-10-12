"""Local source preparation must preserve originals and mismatched destinations."""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare


class PrepareTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        source = root / "originals"
        source.mkdir()
        output = root / "cache"
        contents = b"original PDF bytes for a local preparation test"
        (source / "sample.pdf").write_bytes(contents)
        cards = [dict(id="sample", filename="sample.pdf", sha256=hashlib.sha256(contents).hexdigest())]
        return source, output, cards, contents

    def test_verified_copy_then_identical_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, cards, contents = self.fixture(directory)
            result = prepare.prepare_sources(source, output, cards)
            self.assertFalse(result[0]["reused"])
            self.assertEqual((output / "sample.pdf").read_bytes(), contents)
            inode = (output / "sample.pdf").stat().st_ino
            self.assertTrue(prepare.prepare_sources(source, output, cards)[0]["reused"])
            self.assertEqual((output / "sample.pdf").stat().st_ino, inode)
            self.assertEqual((source / "sample.pdf").read_bytes(), contents)
            self.assertEqual(sorted(p.name for p in output.iterdir()), ["sample.pdf"])

    def test_wrong_source_hash_does_not_create_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, cards, _ = self.fixture(directory)
            cards[0]["sha256"] = "a" * 64
            with self.assertRaisesRegex(ValueError, "source hash"):
                prepare.prepare_sources(source, output, cards)
            self.assertFalse(output.exists())

    def test_wrong_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, cards, _ = self.fixture(directory)
            output.mkdir()
            (output / "sample.pdf").write_bytes(b"unique existing evidence")
            with self.assertRaisesRegex(ValueError, "refusing to replace"):
                prepare.prepare_sources(source, output, cards)
            self.assertEqual((output / "sample.pdf").read_bytes(), b"unique existing evidence")

    def test_complete_inventory_validated_before_first_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, cards, _ = self.fixture(directory)
            cards.append(dict(id="missing", filename="missing.pdf", sha256="a" * 64))
            with self.assertRaises(ValueError):
                prepare.prepare_sources(source, output, cards)
            self.assertFalse(output.exists())

    def test_bad_basename_same_root_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, cards, _ = self.fixture(directory)
            with self.assertRaisesRegex(ValueError, "must differ"):
                prepare.prepare_sources(source, source, cards)
            bad = [dict(cards[0], filename="../sample.pdf")]
            with self.assertRaisesRegex(ValueError, "basename"):
                prepare.prepare_sources(source, output, bad)
            (source / "alias.pdf").symlink_to(source / "sample.pdf")
            with self.assertRaisesRegex(ValueError, "source hash"):
                prepare.prepare_sources(source, output, [dict(cards[0], filename="alias.pdf")])

    def test_atomic_publication_does_not_clobber_racing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, cards, _ = self.fixture(directory)

            def race(temporary, destination):
                destination.write_bytes(b"racing unique contents")
                raise FileExistsError()

            with mock.patch.object(prepare.os, "link", side_effect=race):
                with self.assertRaisesRegex(ValueError, "appeared with wrong hash"):
                    prepare.prepare_sources(source, output, cards)
            self.assertEqual((output / "sample.pdf").read_bytes(), b"racing unique contents")
            self.assertEqual(sorted(p.name for p in output.iterdir()), ["sample.pdf"])


if __name__ == "__main__":
    unittest.main()
