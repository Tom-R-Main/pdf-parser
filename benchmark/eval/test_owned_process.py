"""Actual descendant regressions for both external-OCR runners."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest import mock

import ocr_profile
import recorded_ocr
from owned_process import cleanup_process_group, live_group_members


@unittest.skipUnless(os.name == 'posix', 'requires POSIX process groups')
class OwnedProcessTests(unittest.TestCase):
    def test_both_runners_remove_term_ignoring_descendants_after_leader_exit_and_timeout(self):
        for name, runner in [('profile', ocr_profile.run), ('recorded', recorded_ocr.run)]:
            for mode in ('success', 'timeout'):
                with self.subTest(runner=name, mode=mode), tempfile.TemporaryDirectory() as directory:
                    output = Path(directory)
                    ready = output / 'ready.json'
                    descendant = (
                        'import json,os,signal,time;from pathlib import Path;'
                        'signal.signal(signal.SIGTERM,signal.SIG_IGN);'
                        f'Path({str(ready)!r}).write_text(json.dumps(dict(pid=os.getpid(),group=os.getpgrp())));'
                        'time.sleep(30)'
                    )
                    leader = (
                        'import subprocess,sys,time;from pathlib import Path;'
                        f'subprocess.Popen([sys.executable,"-c",{descendant!r}]);'
                        f'p=Path({str(ready)!r});'
                        '\nwhile not p.exists(): time.sleep(0.01)\n'
                        + ('time.sleep(30)' if mode == 'timeout' else 'sys.exit(0)')
                    )
                    try:
                        command = [sys.executable, '-c', leader]
                        if name == 'profile':
                            result = runner(output, mode, command, timeout=1)
                        else:
                            result = runner(command, output, mode, dict(os.environ), timeout=1)
                        self.assertTrue(ready.exists(), 'the stubborn descendant must start before the deadline')
                        child = json.loads(ready.read_text())
                        self.assertEqual(child['group'], result['pid'])
                        self.assertEqual(live_group_members(result['pid']), [])
                        self.assertIn('SIGKILL', result['process_group_cleanup']['signals_sent'])
                        self.assertEqual(result['timed_out'], mode == 'timeout')
                        self.assertEqual(result['exit_code'] == 0, mode == 'success')
                        self.assertTrue(result.get('owned_group_cleanup', result.get('owned_process_group_cleaned')))
                    finally:
                        if ready.exists():
                            group = json.loads(ready.read_text())['group']
                            if live_group_members(group):
                                os.killpg(group, signal.SIGKILL)

    def test_cleanup_failure_is_not_reported_as_success(self):
        child = mock.Mock(pid=123456)
        with mock.patch('owned_process.os.killpg'), \
             mock.patch('owned_process.live_group_members', return_value=[123456]):
            with self.assertRaisesRegex(RuntimeError, 'still has running members'):
                cleanup_process_group(child, term_grace=0, kill_grace=0)
        child.wait.assert_not_called()


if __name__ == '__main__':
    unittest.main()
