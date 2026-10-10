import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

const inspect = promisify(execFile);
const kill = pid => { try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; } };

/** Give each live parent a chance to reap killed children before killing it.
 * A blocked parent or unavailable process inventory can leave cleanup uncertain;
 * callers retain that gap on the original failure instead of claiming success. */
export async function terminateSubprocess(child, grouped) {
  if (!child.pid) return;
  if (!grouped) { child.kill('SIGKILL'); return; }
  const deadline = performance.now() + 1000;
  let gap;
  try {
    while (performance.now() < deadline) {
      const { stdout } = await inspect('ps', ['-eo', 'pid=,ppid=,pgid='], { timeout: 200, maxBuffer: 1024 * 1024 });
      const members = stdout.trim().split('\n').map(line => line.trim().split(/\s+/u).map(Number))
        .filter(([pid, parent, group]) => Number.isSafeInteger(pid) && pid > 1 && Number.isSafeInteger(parent) && group === child.pid && pid !== child.pid);
      if (members.length === 0) break;
      const parents = new Set(members.map(([, parent]) => parent));
      for (const [pid] of members) if (!parents.has(pid)) kill(pid);
      // Do not promote an unreaped zombie to a terminated subtree. A fresh
      // inventory must show removal before its parent becomes a leaf.
      await delay(20);
    }
    if (performance.now() >= deadline) gap = new Error('Descendant reaping exceeded the cleanup grace period');
  } catch (cause) { gap = new Error('Descendant inventory or termination failed', { cause }); }
  // Also catches descendants forked after the last inventory. Escaped sessions
  // and parents unable to reap are outside this bounded cleanup qualification.
  try { kill(-child.pid); } catch (cause) { gap ??= new Error('Process group termination failed', { cause }); child.kill('SIGKILL'); }
  if (gap) throw gap;
}
