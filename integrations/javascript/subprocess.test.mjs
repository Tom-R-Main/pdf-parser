import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { extractPdfDocument, extractPdfPages } from './index.mjs';

for (const [name, extract] of [['batch', extractPdfDocument], ['stream', extractPdfPages]]) {
  test(`${name} cancellation lets nested parents reap descendants before termination`, { skip: process.platform === 'win32' }, async t => {
    const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-reaping-'));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const pids = join(directory, 'pids.json');
    const reaped = join(directory, 'reaped.log');
    const middle = `const fs=require('node:fs'); const child=require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)']);
      fs.writeFileSync(${JSON.stringify(pids)},JSON.stringify({middle:process.pid,leaf:child.pid}));
      child.on('exit',()=>fs.appendFileSync(${JSON.stringify(reaped)},'leaf-reaped\\n')); setInterval(()=>{},1000);`;
    const binaryPath = join(directory, 'parser');
    await writeFile(binaryPath, `#!${process.execPath}\nconst fs=require('node:fs');
      const child=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(middle)}]);
      child.on('exit',()=>fs.appendFileSync(${JSON.stringify(reaped)},'middle-reaped\\n')); setInterval(()=>{},1000);\n`, { mode: 0o700 });
    const controller = new AbortController();
    const operation = extract(Buffer.from('%PDF-test'), { binaryPath, timeoutMs: 5000, signal: controller.signal, onPage() {} });
    let audit;
    for (let attempt = 0; attempt < 100 && !audit; attempt++) {
      try { audit = JSON.parse(await readFile(pids, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; await delay(20); }
    }
    assert.ok(audit, 'nested descendant must exist before cancellation');
    controller.abort();
    await assert.rejects(operation, { code: 'aborted' });
    assert.equal(await readFile(reaped, 'utf8'), 'leaf-reaped\nmiddle-reaped\n');
    for (const pid of Object.values(audit)) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  });
}
