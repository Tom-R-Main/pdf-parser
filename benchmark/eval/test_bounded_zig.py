#!/usr/bin/env python3
"""Exercise allocation limits and process ownership without running Zig."""

from __future__ import annotations

import hashlib
import contextlib
import io
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from types import SimpleNamespace

import bounded_zig


class BoundedBuildTests(unittest.TestCase):
    def setUp(self):
        parent = bounded_zig.REPO_ROOT / "benchmark/eval/outputs/topology-order-2026-10-12"
        parent.mkdir(parents=True, exist_ok=True)
        # The harness retains even test evidence. No temporary cache is placed in
        # a system directory, and no test cleanup deletes previous run results.
        self.root = Path(tempfile.mkdtemp(prefix="bounded-runner-test-", dir=parent))
        self.cache = self.root / "cache"
        self.log = self.root / "command.log"
        self.receipt = self.root / "receipt.json"

    def run_child(self, script: str, **options) -> int:
        return bounded_zig.run_command(
            [sys.executable, "-c", script], cache_dir=self.cache,
            log_path=self.log, receipt_path=self.receipt,
            budget_bytes=1024 * 1024, min_free_bytes=0, poll_seconds=0.05,
            **options,
        )

    def read_receipt(self):
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt["log_sha256"], hashlib.sha256(self.log.read_bytes()).hexdigest())
        self.assertFalse(receipt["strict_filesystem_quota"])
        self.assertEqual(receipt["deletions"], [])
        return receipt

    def test_success_preserves_log_cache_and_identity(self):
        result = self.run_child(
            "import os,pathlib; "
            "p=pathlib.Path(os.environ['ZIG_GLOBAL_CACHE_DIR'])/'item'; "
            "p.write_bytes(b'cache'); print('build completed')"
        )
        receipt = self.read_receipt()
        self.assertEqual(result, 0)
        self.assertEqual(receipt["status"], "completed")
        self.assertGreater(receipt["peak_allocated_bytes"], 0)
        self.assertEqual((self.cache / "global/item").read_bytes(), b"cache")
        self.assertIn(b"build completed", self.log.read_bytes())
        self.assertEqual(len(receipt["executable"]["sha256"]), 64)

    def test_limit_stops_owned_parent_and_child_but_not_unrelated_process(self):
        child_ready = self.root / "child-ready"
        child_stopped = self.root / "child-stopped"
        sleeper = (
            "import pathlib,signal,time; "
            f"p=pathlib.Path({str(child_stopped)!r}); "
            "signal.signal(signal.SIGTERM, lambda *a: (p.write_text('terminated'), exit(0))); "
            f"pathlib.Path({str(child_ready)!r}).write_text('ready'); "
            "time.sleep(60)"
        )
        script = (
            "import os,pathlib,subprocess,sys,time\n"
            f"subprocess.Popen([sys.executable,'-c',{sleeper!r}])\n"
            f"ready=pathlib.Path({str(child_ready)!r})\n"
            "while not ready.exists(): time.sleep(.01)\n"
            # Once the write crosses the limit, the monitor may stop the group
            # before the writer can print again. Log readiness before growing it.
            "print('child group ready',flush=True)\n"
            "p=pathlib.Path(os.environ['ZIG_GLOBAL_CACHE_DIR'])/'large'\n"
            "with p.open('wb') as f:\n"
            " f.write(b'x'*(2*1024*1024)); f.flush(); os.fsync(f.fileno())\n"
            "time.sleep(60)\n"
        )
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        try:
            result = self.run_child(script)
            receipt = self.read_receipt()
            self.assertEqual(result, 124)
            self.assertEqual(receipt["status"], "allocation_budget_exceeded")
            self.assertGreater(receipt["observed_budget_overshoot_bytes"], 0)
            self.assertIsNotNone(receipt["command_exit_code"])
            self.assertEqual(child_stopped.read_text(), "terminated")
            self.assertIsNone(unrelated.poll(), "runner killed an unrelated process")
            self.assertTrue((self.cache / "global/large").exists())
            self.assertIn(b"child group ready", self.log.read_bytes())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_budget_stop_does_not_require_output_after_allocation(self):
        # Hold the writer after allocation so the monitor must stop it without
        # relying on a later log line or successful command exit.
        result = self.run_child(
            "import os,pathlib,time\n"
            "p=pathlib.Path(os.environ['ZIG_GLOBAL_CACHE_DIR'])/'large'\n"
            "with p.open('wb') as f:\n"
            " f.write(b'x'*(2*1024*1024)); f.flush(); os.fsync(f.fileno())\n"
            "time.sleep(60)\n"
            "print('must not reach this line',flush=True)\n"
        )
        receipt = self.read_receipt()
        self.assertEqual(result, 124)
        self.assertEqual(receipt["status"], "allocation_budget_exceeded")
        self.assertNotEqual(receipt["command_exit_code"], 0)
        self.assertGreater(receipt["observed_budget_overshoot_bytes"], 0)
        self.assertEqual(self.log.read_bytes(), b"")

    def test_preexisting_cache_over_budget_never_starts_command(self):
        self.cache.mkdir()
        cached = self.cache / "preexisting"
        cached.write_bytes(b"x" * (2 * 1024 * 1024))
        marker = self.root / "must-not-start"
        result = self.run_child(f"import pathlib; pathlib.Path({str(marker)!r}).touch()")
        self.assertEqual(result, 125)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "preflight_allocation_budget_exceeded")
        self.assertIsNone(receipt["pid"])
        self.assertFalse(marker.exists())
        self.assertEqual(cached.stat().st_size, 2 * 1024 * 1024)

    def test_existing_evidence_is_not_overwritten(self):
        self.receipt.write_text("prior evidence")
        with self.assertRaises(FileExistsError):
            self.run_child("print('must not start')")
        self.assertEqual(self.receipt.read_text(), "prior evidence")
        self.assertFalse(self.log.exists())

    def test_free_space_floor_prevents_start(self):
        result = bounded_zig.run_command(
            [sys.executable, "-c", "raise RuntimeError('must not start')"],
            cache_dir=self.cache, log_path=self.log, receipt_path=self.receipt,
            budget_bytes=1024 * 1024, min_free_bytes=2**63, poll_seconds=0.05,
        )
        self.assertEqual(result, 125)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "preflight_free_space_floor_crossed")
        self.assertIsNone(receipt["pid"])

    def test_cli_rejects_cache_and_jobs_override(self):
        for argument in ("--cache-dir=/tmp/other", "--global-cache-dir", "-j8"):
            with self.subTest(argument=argument), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                bounded_zig.main(["test", "--", argument])
            self.assertEqual(error.exception.code, 2)

    def test_cli_passes_task_cache_job_limit_and_step_to_selected_tool(self):
        tool = self.root / "fake-zig"
        tool.write_text(
            f"#!{sys.executable}\n"
            "import json,os,pathlib,sys\n"
            "p=pathlib.Path(os.environ['ZIG_GLOBAL_CACHE_DIR'])/'arguments.json'\n"
            "p.write_text(json.dumps(sys.argv[1:]))\n"
            "print('selected tool completed')\n"
        )
        tool.chmod(0o700)
        with contextlib.redirect_stdout(io.StringIO()):
            result = bounded_zig.main([
                "test", "--zig", str(tool), "--cache-dir", str(self.cache),
                "--log", str(self.log), "--receipt", str(self.receipt),
                "--min-free-gib", "0", "--poll-seconds", "0.05", "--", "--summary", "all",
            ])
        self.assertEqual(result, 0)
        arguments = json.loads((self.cache / "global/arguments.json").read_text())
        self.assertEqual(arguments, [
            "build", "test", "-j2", "--cache-dir", str(self.cache),
            "--summary", "all",
        ])
        receipt = self.read_receipt()
        self.assertEqual(receipt["executable"]["sha256"], hashlib.sha256(tool.read_bytes()).hexdigest())
        self.assertEqual(receipt["cache_environment"], {
            "ZIG_LOCAL_CACHE_DIR": str(self.cache),
            "ZIG_GLOBAL_CACHE_DIR": str(self.cache / "global"),
        })

    @unittest.skipUnless(shutil.which("zig"), "installed Zig is unavailable")
    def test_installed_zig_env_observes_owned_global_cache_without_building(self):
        # zig env reports configuration without compiling. Capture its complete
        # output privately, checking only the cache variables we supplied.
        env = os.environ.copy()
        global_cache = self.cache / "global"
        env["ZIG_GLOBAL_CACHE_DIR"] = str(global_cache)
        env["ZIG_LOCAL_CACHE_DIR"] = str(self.cache)
        result = subprocess.run([shutil.which("zig"), "env"], cwd=bounded_zig.REPO_ROOT, env=env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, "installed zig env failed")
        selected = {}
        for name in ("global_cache_dir", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR"):
            match = re.search(r"\." + name + r'\s*=\s*("(?:[^"\\]|\\.)*")', result.stdout)
            self.assertIsNotNone(match, f"installed compiler did not report {name}")
            selected[name] = json.loads(match.group(1))
        # Zig may report the selected global directory relative to its cwd.
        self.assertEqual((bounded_zig.REPO_ROOT / selected["global_cache_dir"]).resolve(), global_cache)
        self.assertEqual(selected["ZIG_GLOBAL_CACHE_DIR"], str(global_cache))
        self.assertEqual(selected["ZIG_LOCAL_CACHE_DIR"], str(self.cache))
        # Zig 0.17 opens/creates its selected global directory even for env;
        # it must not create compiled artifacts during this configuration probe.
        self.assertFalse(any(path.is_file() for path in self.cache.rglob("*")))
        (self.root / "selected-compiler-cache-environment.json").write_text(json.dumps(selected, indent=2) + "\n")

    def test_nonzero_command_exit_is_preserved(self):
        self.assertEqual(self.run_child("import sys; print('failed'); sys.exit(7)"), 7)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "command_failed")
        self.assertEqual(receipt["command_exit_code"], 7)

    def test_sigterm_retains_receipt_and_stops_owned_tool(self):
        ready = self.root / "ready"
        stopped = self.root / "stopped"
        tool = self.root / "fake-zig"
        tool.write_text(
            f"#!{sys.executable}\n"
            "import pathlib,signal,time\n"
            f"p=pathlib.Path({str(stopped)!r})\n"
            "signal.signal(signal.SIGTERM, lambda *a: (p.write_text('terminated'), exit(0)))\n"
            f"pathlib.Path({str(ready)!r}).write_text('ready')\n"
            "time.sleep(60)\n"
        )
        tool.chmod(0o700)
        runner = subprocess.Popen([
            sys.executable, str(Path(bounded_zig.__file__)), "test", "--zig", str(tool),
            "--cache-dir", str(self.cache), "--log", str(self.log), "--receipt", str(self.receipt),
            "--min-free-gib", "0", "--poll-seconds", "0.05",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and runner.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "tool did not become ready")
            runner.terminate()
            self.assertEqual(runner.wait(timeout=5), 130)
            self.assertEqual(stopped.read_text(), "terminated")
            self.assertEqual(self.read_receipt()["status"], "interrupted")
        finally:
            if runner.poll() is None:
                runner.terminate()
                runner.wait(timeout=5)

    def test_symlinked_cache_is_rejected(self):
        actual = self.root / "actual"
        actual.mkdir()
        self.cache.symlink_to(actual, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.run_child("print('must not start')")
        self.assertFalse(self.receipt.exists())

    @contextlib.contextmanager
    def child_finishing_during_observation(self, action: str, *, measurement="allocation", exit_code=0, measurement_error=False):
        """Complete a real child after a sampled value, before the runner poll.

        Synchronize on child readiness and exit, rather than relying on sampling
        call counts or timing a write to land in a narrow race window.
        """
        ready = self.root / "race-ready"
        released = self.root / "race-released"
        finished = self.root / "race-finished"
        script = (
            "import os,pathlib,sys,time\n"
            f"pathlib.Path({str(ready)!r}).touch()\n"
            f"while not pathlib.Path({str(released)!r}).exists(): time.sleep(.005)\n"
            + action + "\n"
            + f"pathlib.Path({str(finished)!r}).touch()\n"
            + f"sys.exit({exit_code})\n"
        )
        actual_popen = subprocess.Popen
        actual_allocated = bounded_zig.allocated_bytes
        owned = {}

        def launch(*args, **kwargs):
            proc = actual_popen(*args, **kwargs)
            if kwargs.get("start_new_session"):
                owned["process"] = proc
            return proc

        def complete_after_read(value):
            if "process" in owned and not released.exists():
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                if not ready.exists():
                    raise TimeoutError("race child did not become ready")
                released.touch()
                owned["process"].wait(timeout=5)
            return value

        def allocation(path):
            if finished.exists() and measurement_error:
                raise PermissionError("controlled final measurement failure")
            value = actual_allocated(path)
            return complete_after_read(value) if measurement == "allocation" else value

        def free_space(_path):
            value = SimpleNamespace(free=0 if finished.exists() else 200)
            return complete_after_read(value) if measurement == "free" else value

        with mock.patch.object(bounded_zig.subprocess, "Popen", side_effect=launch), mock.patch.object(bounded_zig, "allocated_bytes", side_effect=allocation):
            if measurement == "free":
                with mock.patch.object(bounded_zig.shutil, "disk_usage", side_effect=free_space):
                    yield script
            else:
                yield script

    def test_final_allocation_breach_rejects_real_child_success(self):
        action = (
            "p=pathlib.Path(os.environ['ZIG_GLOBAL_CACHE_DIR'])/'final-large'\n"
            "with p.open('wb') as f:\n"
            " f.write(b'x'*(2*1024*1024)); f.flush(); os.fsync(f.fileno())"
        )
        with self.child_finishing_during_observation(action) as script:
            result = self.run_child(script)
        receipt = self.read_receipt()
        self.assertEqual(result, 124)
        self.assertEqual(receipt["command_exit_code"], 0)
        self.assertEqual(receipt["status"], "allocation_budget_exceeded")
        self.assertEqual(receipt["final_breach"], "allocation_budget_exceeded")
        self.assertGreater(receipt["last_allocated_bytes"], receipt["budget_allocated_bytes"])

    def test_final_free_floor_breach_rejects_real_child_success(self):
        with self.child_finishing_during_observation("print('completed')", measurement="free") as script:
            result = bounded_zig.run_command(
                [sys.executable, "-c", script], cache_dir=self.cache,
                log_path=self.log, receipt_path=self.receipt,
                budget_bytes=1024 * 1024, min_free_bytes=100, poll_seconds=.05,
            )
        receipt = self.read_receipt()
        self.assertEqual(result, 124)
        self.assertEqual(receipt["command_exit_code"], 0)
        self.assertEqual(receipt["status"], "free_space_floor_crossed")
        self.assertEqual(receipt["final_breach"], "free_space_floor_crossed")
        self.assertLess(receipt["last_free_bytes"], receipt["minimum_free_bytes"])

    def test_final_breach_keeps_original_command_failure(self):
        with self.child_finishing_during_observation("print('command failed')", measurement="free", exit_code=7) as script:
            result = bounded_zig.run_command(
                [sys.executable, "-c", script], cache_dir=self.cache,
                log_path=self.log, receipt_path=self.receipt,
                budget_bytes=1024 * 1024, min_free_bytes=100, poll_seconds=.05,
            )
        receipt = self.read_receipt()
        self.assertEqual(result, 7)
        self.assertEqual(receipt["status"], "command_failed")
        self.assertEqual(receipt["final_breach"], "free_space_floor_crossed")

    def test_final_measurement_error_rejects_success(self):
        with self.child_finishing_during_observation("print('completed')", measurement_error=True) as script:
            result = self.run_child(script)
        receipt = self.read_receipt()
        self.assertEqual(result, 125)
        self.assertEqual(receipt["status"], "final_measurement_failed")
        self.assertEqual(receipt["command_exit_code"], 0)
        self.assertIn("PermissionError", receipt["final_measurement_error"])

    def test_final_measurement_error_keeps_original_command_failure(self):
        with self.child_finishing_during_observation("print('failed')", exit_code=7, measurement_error=True) as script:
            result = self.run_child(script)
        receipt = self.read_receipt()
        self.assertEqual(result, 7)
        self.assertEqual(receipt["status"], "command_failed")
        self.assertIn("PermissionError", receipt["final_measurement_error"])


if __name__ == "__main__":
    unittest.main()
