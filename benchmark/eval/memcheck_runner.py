#!/usr/bin/env python3
"""Qualified Memcheck checks at the parser CLI and shared-library boundaries.

No tools are installed. Missing prerequisites and incomplete checks fail the run.
--without-valgrind is an explicit native smoke mode, never Memcheck evidence.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ERROR_EXIT = 77
FIXTURES = (
    "clean_born_digital/clean-native.pdf",
    "academic_two_column/two-column.pdf",
    "scanned_typewritten/image-only-page.pdf",
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def resolve_tool(name):
    tool = shutil.which(name)
    require(tool is not None, "required executable unavailable: " + name)
    # Preserve a virtualenv's invocation path: resolving its Python symlink
    # would select the global interpreter prefix instead of the requested one.
    return str(Path(tool).absolute())


class Run:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.summary = {"mode": "native-smoke" if args.without_valgrind else "memcheck",
                        "memcheck_proven": False, "qualification": "not-run", "status": "running",
                        "platform": platform.platform(), "machine": platform.machine(),
                        "allocator": "diagnostic libc-backed; nested arenas remain slab-visible",
                        "unchecked_boundaries": ["logical suballocation boundaries inside live arena slabs"],
                        "parity_ignored_fields": ["document_finished.elapsed_ms (measured wall time; validated nonnegative)"],
                        "suppression_policy": "default suppressions disabled; no project suppressions",
                        "commands": [], "coverage": [], "skipped": [], "artifacts": {}}
        self.summary["failed_checks"] = []
        self.vg = None

    def command(self, name, argv, expected=0, env=None, checked=False):
        index = len(self.summary["commands"])
        stem = self.out / ("%02d-%s" % (index, name))
        command = list(map(str, argv))
        xml_path = stem.with_suffix(".xml")
        if checked and self.vg:
            command = [self.vg, "--tool=memcheck", "--leak-check=full", "--show-leak-kinds=all",
                       "--errors-for-leak-kinds=definite,indirect,possible", "--track-origins=yes",
                       "--num-callers=100", "--error-exitcode=" + str(ERROR_EXIT),
                       "--default-suppressions=no", "--xml=yes", "--xml-file=" + str(xml_path)] + command
            command = command[:1] + ["--suppressions=" + str(path.resolve()) for path in self.args.suppressions] + command[1:]
        record = {"name": name, "argv": command, "timeout_seconds": self.args.timeout,
                  "expected_exit": expected, "checked_by_memcheck": bool(checked and self.vg),
                  "stdout": str(stem.with_suffix(".stdout")), "stderr": str(stem.with_suffix(".stderr"))}
        if env:
            # Only intentional non-secret selection knobs are persisted.
            record["environment"] = {key: env[key] for key in ("PDF_PARSER_LIB", "PYTHONPATH", "PYTHONMALLOC", "__PYVENV_LAUNCHER__") if key in env}
        self.summary["commands"].append(record)
        start = time.monotonic()
        with stem.with_suffix(".stdout").open("wb") as stdout, stem.with_suffix(".stderr").open("wb") as stderr:
            try:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=stdout, stderr=stderr,
                                        timeout=self.args.timeout, check=False)
                record["exit_code"] = result.returncode
            except subprocess.TimeoutExpired:
                record["timed_out"] = True
                raise RuntimeError(name + " timed out; teardown unverified")
            finally:
                record["elapsed_seconds"] = time.monotonic() - start
        if checked and self.vg:
            require(b"WARNING: unhandled" not in stem.with_suffix(".stderr").read_bytes(),
                    name + " used a checker-unsupported syscall/ioctl; runtime coverage incomplete")
            require(xml_path.is_file(), name + " produced no Memcheck XML")
            tree = ET.parse(xml_path).getroot()
            require(tree.findtext("tool") == "memcheck", name + " did not run Memcheck")
            require(any(status.findtext("state") == "FINISHED" for status in tree.findall("status")),
                    name + " did not complete Memcheck")
            errors = [{"kind": error.findtext("kind"),
                       "message": error.findtext("what") or error.findtext("xwhat/text")}
                      for error in tree.findall("error")]
            record["memcheck"] = {"xml": str(xml_path), "errors": errors,
                                  "error_counts": [{"unique": pair.findtext("unique"), "count": pair.findtext("count")}
                                                   for pair in tree.findall("errorcounts/pair")],
                                  "suppression_counts": [{"name": pair.findtext("name"), "count": pair.findtext("count")}
                                                         for pair in tree.findall("suppcounts/pair")]}
        require(result.returncode == expected, "%s exited %d, expected %d; see %s" % (name, result.returncode, expected, stem))
        if checked and self.vg:
            if expected != ERROR_EXIT:
                require(not [error for error in errors if error["kind"] != "Leak_StillReachable"],
                        name + " contains Memcheck errors despite zero exit")
        return stem.with_suffix(".stdout").read_bytes(), record

    def checked(self, name, argv, env=None):
        output, record = self.command(name, argv, env=env, checked=True)
        self.summary["coverage"].append({"name": name, "memcheck": record["checked_by_memcheck"]})
        return output

    def run(self):
        if self.args.suppressions:
            self.summary["suppression_policy"] = "default suppressions disabled; explicit reviewed suppression files"
            for path in self.args.suppressions:
                require(path.is_file(), "suppression file unavailable: " + str(path))
                self.summary["artifacts"][str(path.resolve())] = digest(path)
        cc = resolve_tool(self.args.cc)
        prefix = self.args.prefix.resolve()
        build_info_path = prefix / "build-info.json"
        require(build_info_path.is_file(), "missing diagnostic build identity: " + str(build_info_path))
        build_info = json.loads(build_info_path.read_text())
        require(build_info.get("allocator") == "libc" and build_info.get("optimize") == "debug",
                "expected diagnostic libc-backed debug build")
        require(build_info.get("cpu") == "baseline", "diagnostic build must use baseline CPU features")
        require(build_info.get("zig_version") == "0.17.0", "diagnostic build did not use pinned Zig 0.17.0")
        self.summary["build_info"] = build_info
        self.summary["artifacts"][str(build_info_path)] = digest(build_info_path)
        parser = prefix / "bin/pdf-parser"
        arena = prefix / "bin/memcheck-arena"
        library = prefix / "lib" / ("libpdf_parser.dylib" if sys.platform == "darwin" else "libpdf_parser.so")
        for path in (parser, library, arena):
            require(path.is_file(), "missing diagnostic artifact: " + str(path))
            self.summary["artifacts"][str(path)] = digest(path)
        for path in ("memcheck_runner.py", "memcheck_probe.c", "memcheck_abi.c", "memcheck_python.py"):
            source = ROOT / "benchmark/eval" / path
            self.summary["artifacts"][str(source)] = digest(source)
        revision, _ = self.command("revision", ["git", "rev-parse", "HEAD"])
        status, _ = self.command("git-status", ["git", "status", "--short"])
        diff, _ = self.command("git-diff", ["git", "diff", "HEAD", "--", "."])
        self.summary.update(revision=revision.decode().strip(), dirty_status=status.decode(),
                            tracked_diff_sha256=hashlib.sha256(diff).hexdigest())
        for name, tool in (("cc-version", cc), ("python-version", sys.executable)):
            output, _ = self.command(name, [tool, "--version"])
            self.summary[name] = output.decode(errors="replace").strip()
        zig = shutil.which(self.args.zig)
        if zig:
            output, _ = self.command("zig-version", [zig, "version"])
            self.summary["zig_in_path"] = {"path": zig, "version": output.decode().strip(),
                                           "note": "binary hash binds artifacts; PATH version alone does not prove build compiler"}
        else:
            self.summary["zig_in_path"] = "unavailable"
        if not self.args.without_valgrind:
            self.vg = resolve_tool(self.args.valgrind)
            output, _ = self.command("valgrind-version", [self.vg, "--version"])
            self.summary["valgrind"] = {"path": self.vg, "version": output.decode().strip(),
                                        "sha256": digest(self.vg)}
            if self.args.valgrind_revision:
                self.summary["valgrind"]["source_revision"] = self.args.valgrind_revision
            probe = self.out / "memcheck-probe"
            self.command("compile-probe", [cc, "-O0", "-g", "-fno-omit-frame-pointer",
                                           ROOT / "benchmark/eval/memcheck_probe.c", "-o", probe])
            self.summary["artifacts"][str(probe)] = digest(probe)
            self.command("qualify-clean", [probe, "clean"], checked=True)
            for case, kind in (("invalid-access", "InvalidWrite"), ("use-after-free", "InvalidRead"),
                               ("leak", "Leak_DefinitelyLost")):
                _, record = self.command("qualify-" + case, [probe, case], expected=ERROR_EXIT, checked=True)
                require(any(error["kind"] == kind for error in record["memcheck"]["errors"]),
                        "qualification did not identify " + kind)
            self.command("qualify-library-clean", [probe, "library-clean", library], checked=True)
            self.summary["qualification"] = "passed"
        else:
            self.summary["qualification"] = "skipped-native-smoke"
            self.summary["skipped"].append({"name": "Memcheck qualification and instrumentation", "reason": "explicit --without-valgrind"})
        abi = self.out / "memcheck-abi"
        self.command("compile-abi", [cc, "-O0", "-g", "-fno-omit-frame-pointer", "-I", ROOT / "include",
                                     ROOT / "benchmark/eval/memcheck_abi.c", "-L", library.parent,
                                     "-lpdf_parser", "-Wl,-rpath," + str(library.parent), "-o", abi])
        self.summary["artifacts"][str(abi)] = digest(abi)
        clean = ROOT / "benchmark/eval/corpus" / FIXTURES[0]
        self.checked("abi-lifecycle", [abi, clean])
        arena_output = self.checked("arena-visibility-limit", [arena])
        require(b"logical boundary unchecked" in arena_output, "arena visibility probe did not execute deliberate slab-internal overrun")
        self.summary["arena_visibility"] = "deliberate logical overrun inside a live slab executed; no logical-boundary detection claimed"
        for relative in FIXTURES:
            fixture = ROOT / "benchmark/eval/corpus" / relative
            require(fixture.is_file(), "missing fixture: " + str(fixture))
            self.summary["artifacts"][str(fixture)] = digest(fixture)
            case = fixture.stem
            for fmt in ("text", "artifact-jsonl", "stream-jsonl"):
                arguments = (["extract", fixture] if fmt == "text" else
                             ["extract-adaptive", "--input", fixture, "--format", fmt, "--no-ocr",
                              "--source-id", "memcheck-" + case])
                output = self.checked(case + "-" + fmt, [parser] + arguments)
                if fmt == "text":
                    if case == "clean-native":
                        require(b"Clean born digital" in output, "native text missing")
                    semantic = output
                else:
                    semantic = validate_jsonl(output, fmt, "memcheck-" + case, case == "clean-native")
                if self.args.baseline_prefix:
                    baseline = self.args.baseline_prefix.resolve() / "bin/pdf-parser"
                    require(baseline.is_file(), "baseline binary unavailable")
                    self.summary["artifacts"][str(baseline)] = digest(baseline)
                    normal, _ = self.command("baseline-" + case + "-" + fmt, [baseline] + arguments)
                    require(semantic == (normal if fmt == "text" else validate_jsonl(normal, fmt, "memcheck-" + case, case == "clean-native")),
                            "diagnostic/baseline output mismatch: " + case + " " + fmt)
        for case, payload in (("malformed", b"not a PDF"), ("truncated", b"%PDF-1.7\n")):
            fixture = self.out / (case + ".pdf")
            fixture.write_bytes(payload)
            for command in (["extract", fixture, "--strict"], ["extract-adaptive", "--input", fixture, "--no-ocr", "--strict"]):
                # Rejected input is expected to exit 1; 77 identifies a memory error instead.
                self.command(case + "-" + command[0], [parser] + command, expected=1, checked=True)
                self.summary["coverage"].append({"name": case + "-" + command[0], "memcheck": bool(self.vg)})
        if self.args.python:
            python = resolve_tool(self.args.python)
            env = dict(os.environ, PDF_PARSER_LIB=str(library.resolve()), PYTHONPATH=str(ROOT / "python"), PYTHONMALLOC="malloc")
            if sys.platform == "darwin":
                selection, _ = self.command("python-selection", [python, "-c",
                    "import json,sys,sysconfig; print(json.dumps({'prefix':sys.prefix,'base_prefix':sys.base_prefix,'framework':sysconfig.get_config_var('PYTHONFRAMEWORK')}))"])
                selected = json.loads(selection)
                self.summary["python_selection"] = dict(selected, requested=python)
                actual = Path(selected["base_prefix"]) / "Resources/Python.app/Contents/MacOS/Python"
                if selected["framework"] == "Python" and actual.is_file():
                    # The framework launcher re-execs outside instrumentation.
                    # Enter the interpreter directly but keep its venv selection.
                    env["__PYVENV_LAUNCHER__"] = python
                    python = str(actual.resolve())
                    self.summary["python_selection"]["instrumented_executable"] = python
                    self.summary["artifacts"][python] = digest(python)
            try:
                self.checked("python-binding", [python, ROOT / "benchmark/eval/memcheck_python.py", clean], env=env)
            except (RuntimeError, OSError, ValueError, ET.ParseError) as exc:
                self.summary["failed_checks"].append({"name": "python-binding", "failure": str(exc)})
        else:
            self.summary["skipped"].append({"name": "Python binding", "reason": "--python not requested; C ABI independently exercised"})
        if self.args.ocr:
            require(build_info.get("tesseract_c") is True, "--ocr requires diagnostic tesseract_c build identity")
            ocr = prefix / "bin/memcheck-ocr"
            require(ocr.is_file(), "--ocr requires diagnostic libtesseract driver: " + str(ocr))
            rasterizer = resolve_tool(self.args.rasterizer)
            base = self.out / "ocr"
            self.command("rasterize-ocr", [rasterizer, "-gray", "-singlefile", "-r", "200", "-f", "1", "-l", "1",
                                            ROOT / "benchmark/eval/corpus" / FIXTURES[2], base])
            raster = base.with_suffix(".pgm")
            require(raster.is_file(), "rasterizer produced no PGM")
            self.summary["artifacts"][str(ocr)] = digest(ocr)
            self.summary["artifacts"][str(raster)] = digest(raster)
            self.checked("tesseract-recognition-teardown", [ocr, raster])
        else:
            self.summary["skipped"].append({"name": "Tesseract FFI", "reason": "--ocr not requested"})
        self.summary["status"] = "failed" if self.summary["failed_checks"] else "passed"
        self.summary["memcheck_proven"] = bool(self.vg) and not self.summary["failed_checks"]


def validate_jsonl(output, fmt, source, require_text):
    records = [json.loads(line) for line in output.decode().splitlines() if line.strip()]
    require(records and records[0].get("record_type") == "document_manifest", "JSONL must be manifest-first")
    require(all(record.get("source_id") == source for record in records), "JSONL source identity mismatch")
    require(all(all(key in record for key in ("schema_name", "schema_version", "record_type", "provenance")) for record in records),
            "JSONL missing public contract metadata")
    if require_text:
        require("Clean born digital" in json.dumps(records), "adaptive text missing")
    if fmt == "stream-jsonl":
        events = [record.get("event_type") for record in records]
        require(events[-1] == "document_finished", "stream missing document teardown")
        elapsed_ms = records[-1].get("elapsed_ms")
        require(type(elapsed_ms) is int and elapsed_ms >= 0, "invalid stream elapsed time")
        require(events.count("page_started") == events.count("page_finished") > 0, "page lifecycle imbalance")
        active = False
        for event in events:
            if event == "page_started":
                require(not active, "overlapping page lifecycle")
                active = True
            elif event == "page_finished":
                require(active, "page finished without start")
                active = False
        require(not active, "unfinished page lifecycle")
        # docs/output-schema.md documents this lifecycle wall time. Full raw
        # outputs remain in evidence; every other field participates in parity.
        records[-1] = {key: value for key, value in records[-1].items() if key != "elapsed_ms"}
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=ROOT / "zig-out/memcheck")
    parser.add_argument("--baseline-prefix", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "benchmark/eval/outputs/memcheck" /
                        (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]))
    parser.add_argument("--valgrind", default="valgrind")
    parser.add_argument("--valgrind-revision", help="source revision of an explicitly selected Valgrind fork")
    parser.add_argument("--suppressions", type=Path, action="append", default=[], help="explicit reviewed suppression file; defaults stay disabled")
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--python", help="Python interpreter with cffi for binding checks")
    parser.add_argument("--ocr", action="store_true", help="exercise optional real libtesseract recognition and teardown")
    parser.add_argument("--rasterizer", default="pdftoppm")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--without-valgrind", action="store_true", help="native smoke only; provides no memory-check proof")
    args = parser.parse_args()
    require(args.timeout > 0, "timeout must be positive")
    run = Run(args)
    try:
        run.run()
    except (RuntimeError, OSError, ValueError, ET.ParseError) as exc:
        run.summary["status"] = "failed"
        run.summary["failure"] = str(exc)
        print(str(exc), file=sys.stderr)
    finally:
        run.summary["executed_checks"] = len(run.summary["coverage"])
        run.summary["skip_count"] = len(run.summary["skipped"])
        (run.out / "summary.json").write_text(json.dumps(run.summary, indent=2) + "\n")
        print(json.dumps({"status": run.summary["status"], "memcheck_proven": run.summary["memcheck_proven"],
                          "executed_checks": run.summary["executed_checks"], "skip_count": run.summary["skip_count"],
                          "summary": str(run.out / "summary.json")}))
    return 0 if run.summary["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
