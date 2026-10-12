#!/usr/bin/env python3
"""Run Zig builds with an observed allocation budget and retained evidence.

This monitor is not a filesystem quota: allocation may overshoot between scans.
It never removes caches or evidence, and terminates only its own process group.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone


GIB = 1024**3
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CACHE = REPO_ROOT / ".zig-cache/topology-order-2026-10-12"
DEFAULT_OUTPUT = REPO_ROOT / "benchmark/eval/outputs/topology-order-2026-10-12"


def allocated_bytes(root: Path) -> int:
    """Count allocated filesystem blocks, without following directory symlinks.

    Hard-linked names are counted separately, so the measurement is conservative.
    Files disappearing during a compiler operation are expected; other errors fail
    closed and stop the owned build.
    """
    total = root.lstat().st_blocks * 512

    def walk_error(error: OSError) -> None:
        if not isinstance(error, FileNotFoundError):
            raise error

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirs + files:
            try:
                total += (Path(directory) / name).lstat().st_blocks * 512
            except FileNotFoundError:
                pass
    return total


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for part in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(part)
    return digest.hexdigest()


def checked_path(path: Path, repo_root: Path) -> Path:
    """Reject paths outside the project and symlinked path components."""
    path = Path(os.path.abspath(path))
    path.relative_to(repo_root)
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError(f"symlinked path is not owned by this runner: {component}")
        if component == repo_root:
            break
    return path


def stop_group(proc: subprocess.Popen, grace_seconds: float = 0.5) -> None:
    """Keep the leader unreaped until its process group has been signalled."""
    def send(sig: int) -> None:
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin returns EPERM for a group containing only unreaped zombies.
            # Ignore that case only after checking states; a real denial remains
            # an error rather than being presented as successful termination.
            states = subprocess.run(
                ["ps", "-ax", "-o", "pgid=,stat="], capture_output=True, text=True,
                check=True,
            ).stdout.splitlines()
            for row in states:
                fields = row.split()
                if len(fields) == 2 and fields[0] == str(proc.pid) and not fields[1].startswith("Z"):
                    raise

    send(signal.SIGTERM)
    time.sleep(grace_seconds)
    send(signal.SIGKILL)
    proc.wait(timeout=5)


def run_command(
    command: list[str], *, cache_dir: Path, log_path: Path, receipt_path: Path,
    repo_root: Path = REPO_ROOT, budget_bytes: int = 6 * GIB,
    min_free_bytes: int = 12 * GIB, poll_seconds: float = 1.0,
) -> int:
    """Execute a command; the CLI supplies Zig's explicit cache flags as well."""
    if budget_bytes <= 0 or min_free_bytes < 0 or not 0 < poll_seconds <= 2:
        raise ValueError("budget must be positive, free floor nonnegative, polling in (0, 2]")
    repo_root = repo_root.resolve(strict=True)
    cache_dir = checked_path(cache_dir, repo_root)
    log_path = checked_path(log_path, repo_root)
    receipt_path = checked_path(receipt_path, repo_root)
    if cache_dir == repo_root or repo_root / ".zig-cache" == cache_dir:
        raise ValueError("use an individual task cache, not the project or whole cache root")
    if log_path == receipt_path:
        raise ValueError("log and receipt must be distinct")
    for output in (log_path, receipt_path):
        if output == cache_dir or cache_dir in output.parents:
            raise ValueError("verification evidence must be outside the monitored cache")
        if output.exists():
            raise FileExistsError(f"preserved evidence already exists: {output}")
        output.parent.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)
    global_cache = cache_dir / "global"
    checked_path(global_cache, repo_root).mkdir(exist_ok=True)
    executable = shutil.which(command[0])
    identity = {
        "path": str(Path(executable).resolve()) if executable else command[0],
        "sha256": sha256_file(Path(executable)) if executable else None,
    }
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo_root, capture_output=True, text=True,
        check=False,
    )
    diff = subprocess.run(
        ["git", "diff", "--binary", "HEAD"], cwd=repo_root, capture_output=True,
        check=False,
    )
    receipt = {
        "schema_version": "1.0", "command": command, "cwd": str(repo_root),
        "executable": identity, "git_head": head.stdout.strip() if head.returncode == 0 else None,
        "runner_sha256": sha256_file(Path(__file__)),
        "tracked_diff_sha256": hashlib.sha256(diff.stdout).hexdigest() if diff.returncode == 0 else None,
        "cache_dir": str(cache_dir), "global_cache_dir": str(global_cache),
        "cache_environment": {
            "ZIG_LOCAL_CACHE_DIR": str(cache_dir),
            "ZIG_GLOBAL_CACHE_DIR": str(global_cache),
        },
        "budget_allocated_bytes": budget_bytes, "minimum_free_bytes": min_free_bytes,
        "poll_seconds": poll_seconds, "strict_filesystem_quota": False,
        "started_at": datetime.now(timezone.utc).isoformat(), "sample_count": 0,
        "peak_allocated_bytes": 0, "lowest_free_bytes": None,
        "observed_budget_overshoot_bytes": 0, "status": "starting", "pid": None,
        "deletions": [], "log_path": str(log_path),
    }
    proc = None
    start = time.monotonic()
    last_sample = start
    receipt["maximum_sample_gap_seconds"] = 0.0

    def sample() -> str | None:
        nonlocal last_sample
        size = allocated_bytes(cache_dir)
        free = shutil.disk_usage(cache_dir).free
        now = time.monotonic()
        receipt["maximum_sample_gap_seconds"] = max(receipt["maximum_sample_gap_seconds"], now - last_sample)
        last_sample = now
        receipt["sample_count"] += 1
        receipt["peak_allocated_bytes"] = max(receipt["peak_allocated_bytes"], size)
        receipt["lowest_free_bytes"] = min(receipt["lowest_free_bytes"], free) if receipt["lowest_free_bytes"] is not None else free
        receipt["observed_budget_overshoot_bytes"] = max(receipt["observed_budget_overshoot_bytes"], size - budget_bytes, 0)
        receipt["last_allocated_bytes"] = size
        receipt["last_free_bytes"] = free
        if size > budget_bytes:
            return "allocation_budget_exceeded"
        if free < min_free_bytes:
            return "free_space_floor_crossed"
        return None

    # Exclusive creation protects earlier verification results, including receipts
    # from interrupted invocations. Keep the receipt handle through finalization.
    with receipt_path.open("x", encoding="utf-8") as receipt_handle, log_path.open("xb") as log:
        def interrupted(signum, _frame):
            receipt["termination_signal"] = signum
            raise KeyboardInterrupt

        previous_sigterm = signal.signal(signal.SIGTERM, interrupted)
        result = 125
        try:
            breach = sample()
            if breach:
                receipt["status"] = "preflight_" + breach
                log.write((receipt["status"] + ": build not started\n").encode())
            else:
                env = os.environ.copy()
                env["ZIG_LOCAL_CACHE_DIR"] = str(cache_dir)
                env["ZIG_GLOBAL_CACHE_DIR"] = str(global_cache)
                proc = subprocess.Popen(
                    command, cwd=repo_root, env=env, stdin=subprocess.DEVNULL,
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                )
                receipt["pid"] = proc.pid
                receipt["status"] = "running"
                receipt_handle.write(json.dumps(receipt, indent=2) + "\n")
                receipt_handle.flush()
                while True:
                    # Sample before poll so a just-finished build cannot bypass the
                    # final budget check.
                    breach = sample()
                    if breach:
                        receipt["status"] = breach
                        stop_group(proc)
                        result = 124
                        break
                    child_exit = proc.poll()
                    if child_exit is not None:
                        receipt["status"] = "completed" if child_exit == 0 else "command_failed"
                        result = child_exit if child_exit >= 0 else 128 - child_exit
                        break
                    time.sleep(poll_seconds)
        except KeyboardInterrupt:
            receipt["status"] = "interrupted"
            result = 130
            if proc is not None:
                stop_group(proc)
        except Exception as error:
            receipt["status"] = "runner_error"
            receipt["error"] = f"{type(error).__name__}: {error}"
            if proc is not None:
                stop_group(proc)
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)
            try:
                final_breach = sample()
                if final_breach:
                    receipt["final_breach"] = final_breach
                    # The compiler can finish between a loop observation and
                    # poll(). A final observation must still reject that success.
                    # Keep an earlier failure's reason and exit code intact.
                    if result == 0:
                        receipt["status"] = final_breach
                        result = 124
            except Exception as error:
                receipt["final_measurement_error"] = f"{type(error).__name__}: {error}"
                if result == 0:
                    receipt["status"] = "final_measurement_failed"
                    result = 125
            log.flush()
            receipt["exit_code"] = result
            receipt["command_exit_code"] = proc.returncode if proc is not None else None
            receipt["elapsed_seconds"] = time.monotonic() - start
            receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
            receipt["log_sha256"] = sha256_file(log_path)
            receipt_handle.seek(0)
            receipt_handle.truncate()
            receipt_handle.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
            receipt_handle.flush()
    return result


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    separator = argv.index("--") if "--" in argv else len(argv)
    extra = argv[separator + 1:] if separator < len(argv) else []
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=("build", "test"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--budget-gib", type=float, default=6)
    parser.add_argument("--min-free-gib", type=float, default=12)
    parser.add_argument("--poll-seconds", type=float, default=1)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args(argv[:separator])
    for value in extra:
        if value.startswith(("--cache-dir", "--global-cache-dir", "-j")):
            parser.error("extra arguments cannot override cache paths or job limit")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + "-" + uuid.uuid4().hex[:8]
    cache = checked_path(args.cache_dir, REPO_ROOT)
    command = [args.zig, "build"] + (["test"] if args.step == "test" else [])
    # Zig 0.17 build accepts --cache-dir; its global cache is selected through
    # ZIG_GLOBAL_CACHE_DIR, unlike compile subcommands accepting the global flag.
    command += ["-j2", "--cache-dir", str(cache)] + extra
    log = args.log or DEFAULT_OUTPUT / (run_id + ".log")
    receipt = args.receipt or DEFAULT_OUTPUT / (run_id + ".json")
    result = run_command(
        command, cache_dir=cache, log_path=log, receipt_path=receipt,
        budget_bytes=int(args.budget_gib * GIB), min_free_bytes=int(args.min_free_gib * GIB),
        poll_seconds=args.poll_seconds,
    )
    print(f"build exit {result}; receipt: {receipt}; log: {log}")
    return result


if __name__ == "__main__":
    raise SystemExit(main())
