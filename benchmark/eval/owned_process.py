"""Bounded cleanup of POSIX subprocess groups owned by evaluation runners."""
from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import time


def live_group_members(group: int) -> list[int]:
    """Return running members; zombies no longer execute and await their reaper."""
    members = []
    if Path('/proc/self/stat').exists():
        for entry in Path('/proc').iterdir():
            if not entry.name.isdecimal():
                continue
            try:
                fields = (entry / 'stat').read_text(errors='replace').rpartition(')')[2].split()
            except (FileNotFoundError, ProcessLookupError):
                continue
            if len(fields) < 3:
                raise RuntimeError('Could not inspect process-group membership')
            if int(fields[2]) == group and fields[0] not in ('Z', 'X'):
                members.append(int(entry.name))
    else:
        ps = next((str(path) for path in (Path('/bin/ps'), Path('/usr/bin/ps')) if path.is_file()), None)
        if ps is None:
            raise RuntimeError('No process-group observation route is available')
        result = subprocess.run([ps, '-axo', 'pid=,pgid=,stat='], check=True,
                                capture_output=True, text=True, timeout=2)
        for line in result.stdout.splitlines():
            pid, pgid, state = line.split()
            if int(pgid) == group and not state.startswith(('Z', 'X')):
                members.append(int(pid))
    return sorted(members)


def cleanup_process_group(child: subprocess.Popen, *, term_grace=0.25, kill_grace=2) -> dict:
    """Kill surviving descendants independently of whether the leader has exited."""
    group = child.pid
    if group <= 0:
        raise ValueError('Expected an owned positive process-group ID')
    sent = []

    def send(sig):
        try:
            os.killpg(group, sig)
            sent.append(sig.name)
        except ProcessLookupError:
            pass

    def wait_quiet(seconds):
        deadline = time.monotonic() + seconds
        while True:
            child.poll()  # Reap the owned leader; descendants may have another reaper.
            remaining = live_group_members(group)
            if not remaining:
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.02)

    send(signal.SIGTERM)
    quiet = wait_quiet(term_grace)
    if not quiet:
        send(signal.SIGKILL)
        quiet = wait_quiet(kill_grace)
    if not quiet:
        raise RuntimeError(f'Owned process group still has running members: {group}')
    child.wait(timeout=kill_grace)
    return dict(group=group, signals_sent=sent, remaining_live_members=[],
                scope='No running group members; orphan zombies may await their reaper')
