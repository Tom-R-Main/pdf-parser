import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location("ocr_profile", Path(__file__).with_name("ocr_profile.py"))
profile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(profile)


class OcrProfileTests(unittest.TestCase):
    def test_compiler_identity_uses_cached_selection_not_path_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            aliases = output / "aliases"
            aliases.mkdir()
            cache = []
            for language, alias in (("C", "cc"), ("CXX", "c++")):
                selected = output / ("cached-" + language)
                selected.write_text(f"#!{sys.executable}\nprint('cached {language} version')\n")
                selected.chmod(0o755)
                wrong = aliases / alias
                wrong.write_text(f"#!{sys.executable}\nraise SystemExit('wrong PATH compiler')\n")
                wrong.chmod(0o755)
                cache.append(f"CMAKE_{language}_COMPILER:FILEPATH={selected}\n")
            (output / "CMakeCache.txt").write_text("".join(cache))
            (output / "compile_commands.json").write_text("[]\n")
            with mock.patch.dict(os.environ, {"PATH": str(aliases)}):
                receipt = profile.collect_compilers(output, "cached-test", output)
            for language in ("C", "CXX"):
                identity = receipt["compilers"][language]
                self.assertEqual(identity["version"], f"cached {language} version")
                self.assertEqual(identity["sha256"], profile.sha(output / ("cached-" + language)))
                self.assertEqual(identity["command"]["command"][0], str(output / ("cached-" + language)))
            self.assertEqual(receipt["compile_commands"]["sha256"], profile.sha(output / "compile_commands.json"))

    def test_each_omitted_artifact_is_rejected_before_any_subprocess(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            data = output / "tessdata"
            value = dict(profile_version=1, mode="live_external_ocr", sources=profile.PINS,
                         model_sha256=profile.MODEL_SHA256, runtime={"TESSDATA_PREFIX": str(data)},
                         binaries={name: str(output / "real" / name) for name in ("pdftoppm", "tesseract")},
                         wrappers={name: str(output / "wrappers" / name) for name in ("pdftoppm", "tesseract")},
                         loaded_openjpeg={"path": str(output / "libopenjp2.so")})
            paths = [*value["binaries"].values(), *value["wrappers"].values(), value["loaded_openjpeg"]["path"],
                     str(data / "eng.traineddata"), str(data / "configs/tsv"), str(data / "configs/quiet")]
            value["artifacts"] = dict.fromkeys(paths, "0" * 64)
            self.assertEqual(len(profile.require_artifact_roles(value)), 8)
            source = output / "profile.json"
            for missing in paths:
                with self.subTest(missing=missing):
                    incomplete = value | {"artifacts": {k: v for k, v in value["artifacts"].items() if k != missing}}
                    source.write_text(json.dumps(incomplete))
                    with mock.patch.object(profile, "require_cpu"), \
                         mock.patch.object(profile, "run", side_effect=AssertionError("subprocess before preflight")) as run:
                        with self.assertRaisesRegex(ValueError, "Missing required artifact"):
                            profile.gate(SimpleNamespace(output=output / "gate", profile=source))
                        run.assert_not_called()

    def test_upstream_dotproduct_flag_cannot_become_global(self):
        dot = {"file": "/source/src/arch/dotproduct.cpp", "command": "c++ -ffast-math -c dotproduct.cpp"}
        profile.verify_compile_flags("tesseract", [dot])
        with self.assertRaisesRegex(ValueError, "global floating-point"):
            profile.verify_compile_flags("tesseract", [dot, {"file": "/source/src/lstm/network.cpp", "command": "c++ -ffast-math -c network.cpp"}])
        with self.assertRaisesRegex(ValueError, "global floating-point"):
            profile.verify_compile_flags("openjpeg", [dot])

    def test_archive_integrity_rejects_changed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "archive"
            path.write_bytes(b"original")
            digest = profile.sha(path)
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                profile.require_hash(path, digest)

    def test_cpu_requirement_rejects_missing_fma(self):
        with mock.patch.object(profile.platform, "system", return_value="Linux"), \
             mock.patch.object(profile.platform, "machine", return_value="x86_64"), \
             mock.patch.object(Path, "read_text", return_value="flags : avx sse2"):
            with self.assertRaisesRegex(ValueError, "AVX/FMA"):
                profile.require_cpu()

    def test_wrapper_executes_provider_without_changing_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            provider = path / "provider"
            provider.write_text(f"#!{sys.executable}\nimport os,sys\nprint(repr(sys.argv[1:]))\nprint(os.environ['OCR_PROFILE_TEST'])\n")
            provider.chmod(0o755)
            wrapper = path / "wrapper"
            profile.wrapper(wrapper, provider, {"OCR_PROFILE_TEST": "explicit profile"})
            result = subprocess.run([wrapper, "arbitrary.pdf", "-r", "300"], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ["['arbitrary.pdf', '-r', '300']", "explicit profile"])

    def test_failed_command_keeps_failure_and_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = profile.run(output, "failure", [sys.executable, "-c", "import sys;print('failure evidence',file=sys.stderr);sys.exit(7)"])
            self.assertEqual(result["exit_code"], 7)
            self.assertIn("failure evidence", Path(result["stderr"]).read_text())
            self.assertEqual(profile.sha(Path(result["stderr"])), result["stderr_sha256"])

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_timeout_reaps_owned_process_and_remains_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result = profile.run(Path(directory), "timeout", [sys.executable, "-c", "import time;time.sleep(30)"], timeout=0.1)
            self.assertTrue(result["timed_out"])
            self.assertNotEqual(result["exit_code"], 0)
            self.assertTrue(result["owned_group_cleanup"])
            with self.assertRaises(ProcessLookupError):
                os.kill(result["pid"], 0)


if __name__ == "__main__":
    unittest.main()
