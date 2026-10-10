import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile, readFile, rm, access } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { execFileSync } from 'node:child_process';
import { extractPdfPages } from './stream.mjs';

const input = Buffer.from('%PDF-stream-test');
const hash = (value) => createHash('sha256').update(value).digest('hex');
const inputSha256 = hash(input);
const bbox = { x0: 1, y0: 2, x1: 9, y1: 10 };
const countKeys = ['spans', 'blocks', 'tables', 'route_traces', 'specialist_requests', 'specialist_attempts', 'specialist_responses', 'specialist_results', 'rag_chunks', 'debug_assets'];
const counts = (value = 0) => Object.fromEntries(countKeys.map((key) => [key, ['spans', 'blocks'].includes(key) ? value : 0]));
const routes = (pages) => ({ native_pages: pages, page_routes: pages, region_routes: 0, ocr_regions: 0, table_regions: 0, formula_regions: 0 });
function fixture() {
  const records = [];
  const record = (type, id, fields = {}, refs = {}) => {
    records.push({ schema_name: type, schema_version: '0.14.0', record_type: type, event_type: type,
      event_index: records.length, sequence_scope: type.startsWith('document_') ? 'document' : 'page',
      document_id: 'doc', source_id: inputSha256,
      provenance: { document_id: 'doc', source_id: inputSha256, input_sha256: inputSha256, artifact_id: id,
        span_ids: [], block_ids: [], chunk_ids: [], ...refs }, ...fields });
  };
  record('document_manifest', 'document_manifest', { streaming: true, input_sha256: inputSha256, page_count: 2,
    errors: [], text_contract: { offset_unit: 'utf8_byte', range_convention: 'half_open', page_index_base: 0,
      geometry: { coordinate_space: 'pdf_user_space', unit: 'point', highlight_precision: 'span_bbox', display_transform: null } } });
  for (let p = 0; p < 2; p++) {
    record('page_started', `page-started-${p}`, { page_index: p, status: 'running' });
    const text = `Page ${p} 😀`;
    const view = (id, kind) => ({ text_view_id: `${id}:text`, kind, text_sha256: hash(text), offset_unit: 'utf8_byte', range_convention: 'half_open', normalization: 'none' });
    const refs = { span_ids: [`span-${p}`], block_ids: [`block-${p}`] };
    record('span', `span-${p}`, { span_id: `span-${p}`, page_index: p, text, bbox, text_view: view(`span-${p}`, 'reconciled_span') }, refs);
    record('block', `block-${p}`, { block_id: `block-${p}`, page_index: p, text, bbox, text_view: view(`block-${p}`, 'reconciled_block'),
      source_map: [{ text_start_byte: 0, text_end_byte: Buffer.byteLength(text), source_span_id: `span-${p}`, source_start_byte: 0, source_end_byte: Buffer.byteLength(text) }] }, refs);
    record('page_finished', `page-finished-${p}`, { page_index: p, status: 'completed', artifact_counts: counts(1), route_counts: routes(1) });
  }
  record('document_finished', 'document_finished', { status: 'completed', errors: [], artifact_counts: counts(2), route_counts: routes(2) });
  return records;
}
const jsonl = (records) => records.map((record) => JSON.stringify(record)).join('\n') + '\n';
async function fake(t, script) {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-stream-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'parser');
  const audit = join(directory, 'audit.json');
  await writeFile(path, `#!${process.execPath}\nconst fs=require('node:fs'); const path=process.argv[process.argv.indexOf('--input')+1]; fs.writeFileSync(${JSON.stringify(audit)},JSON.stringify({path,mode:fs.statSync(path).mode&511,input:fs.readFileSync(path).toString(),args:process.argv}));\n${script}\n`, { mode: 0o700 });
  return { path, audit, directory };
}
async function run(t, records = fixture(), extra = {}, code = '') {
  const driver = await fake(t, `process.stdout.write(${JSON.stringify(jsonl(records))}); ${code}`);
  const pages = [];
  const receipt = await extractPdfPages(input, { binaryPath: driver.path, onPage: (page) => pages.push(page), ...extra });
  return { ...driver, pages, receipt };
}

test('streams isolated page projections with global IDs and accepts only final receipt', async (t) => {
  const result = await run(t);
  assert.equal(result.receipt.complete, true);
  assert.equal(result.receipt.pageCount, 2);
  assert.equal(result.receipt.records, 10);
  assert.equal(result.pages[1].sourceText, 'Page 1 😀');
  assert.equal(result.pages[1].sourceMap[0].start, 0);
  assert.equal(result.pages[1].sourceMap[0].sourceSpanId, 'span-1');
  assert.equal(result.pages[1].sourceTextScope, 'page');
  assert.equal(result.pages[1].streamComplete, false);
  const audit = JSON.parse(await readFile(result.audit, 'utf8'));
  assert.equal(audit.mode, 0o600);
  assert.equal(audit.input, input.toString());
  assert.ok(audit.args.includes('stream-jsonl'));
  assert.ok(audit.args.includes('--no-ocr'));
  await assert.rejects(access(audit.path), { code: 'ENOENT' });
});

test('forwards the native allocation budget and validates it before starting', async (t) => {
  const result = await run(t, fixture(), { maxNativePageMemoryBytes: 4096 });
  const { args } = JSON.parse(await readFile(result.audit, 'utf8'));
  assert.equal(args[args.indexOf('--max-page-memory-bytes') + 1], '4096');
  for (const value of [0, -1, 1.5, NaN, Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(extractPdfPages(input, { binaryPath: result.path, onPage() {}, maxNativePageMemoryBytes: value }), RangeError);
  }
});

for (const [diagnostic, code] of [['MemoryBudgetExceeded', 'memory_limit'], ['OutputLimitExceeded', 'output_limit']]) {
  test(`classifies native ${code} without a terminal receipt`, async (t) => {
    const driver = await fake(t, `process.stderr.write('error: ${diagnostic}'); process.exitCode=1;`);
    await assert.rejects(extractPdfPages(input, { binaryPath: driver.path, onPage() {} }), { code });
  });
}

test('awaits callbacks serially even when both pages arrive in one write', async (t) => {
  const driver = await fake(t, `process.stdout.write(${JSON.stringify(jsonl(fixture()))});`);
  let release;
  let entered;
  const firstEntered = new Promise((resolve) => { entered = resolve; });
  const gate = new Promise((resolve) => { release = resolve; });
  const seen = [];
  const extraction = extractPdfPages(input, { binaryPath: driver.path, onPage: async (page) => {
    seen.push(page.pageIndex);
    if (page.pageIndex === 0) { entered(); await gate; }
  } });
  await firstEntered;
  assert.deepEqual(seen, [0]);
  release();
  assert.equal((await extraction).complete, true);
  assert.deepEqual(seen, [0, 1]);
});

for (const [label, mutate] of [
  ['truncated lifecycle', (records) => records.pop()],
  ['event index gap', (records) => { records[2].event_index++; }],
  ['wrong source identity', (records) => { records[2].source_id = 'wrong'; }],
  ['duplicate global artifact', (records) => { records[6].provenance.artifact_id = 'span-0'; }],
  ['page count mismatch', (records) => { records[0].page_count = 3; }],
  ['per-page counts mismatch', (records) => { records[4].artifact_counts.spans++; }],
  ['terminal counts mismatch', (records) => { records.at(-1).artifact_counts.spans++; }],
  ['terminal route counts mismatch', (records) => { records.at(-1).route_counts.native_pages++; }],
  ['record after completion', (records) => { records.push({ ...records.at(-1), event_index: records.length }); }],
  ['artifact page mismatch', (records) => { records[2].page_index = 1; }],
  ['invalid text contract', (records) => { records[0].text_contract.offset_unit = 'utf16_code_unit'; }],
  ['second manifest with distinct id', (records) => { records[1] = { ...records[0], event_index: 1,
    provenance: { ...records[0].provenance, artifact_id: 'other-manifest' } }; }],
]) test(`rejects ${label}`, async (t) => {
  const records = fixture();
  mutate(records);
  await assert.rejects(run(t, records), { code: 'protocol' });
});

for (const limit of [{ maxOutputBytes: 100 }, { maxPageBytes: 100 }, { maxRecordBytes: 100 }, { maxRecords: 3 }]) {
  test(`enforces ${Object.keys(limit)[0]}`, async (t) => {
    await assert.rejects(run(t, fixture(), limit), { code: 'output_limit' });
  });
}
test('rejects page-count budget before callbacks', async (t) => {
  await assert.rejects(run(t, fixture(), { maxPages: 1 }), { code: 'output_limit' });
});
test('fatal UTF-8 decoder rejects malformed bytes', async (t) => {
  const driver = await fake(t, 'process.stdout.write(Buffer.from([255,10]));');
  await assert.rejects(extractPdfPages(input, { binaryPath: driver.path, onPage() {} }), { code: 'protocol' });
});
test('requires terminated JSONL lines', async (t) => {
  const driver = await fake(t, `process.stdout.write(${JSON.stringify(jsonl(fixture()).slice(0, -1))});`);
  await assert.rejects(extractPdfPages(input, { binaryPath: driver.path, onPage() {} }), { code: 'protocol' });
});
test('valid terminal event followed by nonzero exit never succeeds', async (t) => {
  await assert.rejects(run(t, fixture(), {}, 'process.exitCode=2;'), { code: 'document' });
});
test('abort terminates an unresolved callback and cleans private input', async (t) => {
  const controller = new AbortController();
  const driver = await fake(t, `process.stdout.write(${JSON.stringify(jsonl(fixture()))}); setInterval(()=>{},1000);`);
  await assert.rejects(extractPdfPages(input, { binaryPath: driver.path, signal: controller.signal,
    onPage() { controller.abort(); return new Promise(() => {}); } }), { code: 'aborted' });
  const audit = JSON.parse(await readFile(driver.audit, 'utf8'));
  await assert.rejects(access(audit.path), { code: 'ENOENT' });
});
test('callback rejection terminates parser and retains original cause', async (t) => {
  const expected = new Error('callback rejected');
  await assert.rejects(run(t, fixture(), { onPage() { throw expected; } }, 'setInterval(()=>{},1000);'), (error) => error.code === 'callback' && error.cause === expected);
});
test('timeout includes callback backpressure', async (t) => {
  await assert.rejects(run(t, fixture(), { timeoutMs: 200, onPage: () => new Promise(() => {}) }, 'setInterval(()=>{},1000);'), { code: 'timeout' });
});
test('validates limits and required callback before launching', async () => {
  await assert.rejects(extractPdfPages(input, { binaryPath: 'unused' }), TypeError);
  await assert.rejects(extractPdfPages(input, { binaryPath: 'unused', onPage() {}, maxRecords: 0 }), RangeError);
  await assert.rejects(extractPdfPages(input, { binaryPath: 'unused', onPage() {}, signal: AbortSignal.abort() }), { code: 'aborted' });
});
test('input is snapshotted before asynchronous staging', async (t) => {
  const callerBytes = Buffer.from(input);
  const driver = await fake(t, `process.stdout.write(${JSON.stringify(jsonl(fixture()))});`);
  const promise = extractPdfPages(callerBytes, { binaryPath: driver.path, onPage() {} });
  callerBytes.fill(0);
  assert.equal((await promise).inputSha256, inputSha256);
  const audit = JSON.parse(await readFile(driver.audit, 'utf8'));
  assert.equal(audit.input, input.toString());
});
test('missing binary is unavailable and cleans staged input', async () => {
  await assert.rejects(extractPdfPages(input, { binaryPath: '/does-not-exist/pdf-parser', onPage() {} }), { code: 'unavailable' });
});
test('timeout kills POSIX wrapper descendants', { skip: process.platform === 'win32' }, async (t) => {
  const driver = await fake(t, `const child=require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)']); const auditPath=${JSON.stringify('AUDIT_PATH')}; fs.writeFileSync(auditPath,String(child.pid)); setInterval(()=>{},1000);`);
  const pidPath = join(driver.directory, 'child.pid');
  const script = await readFile(driver.path, 'utf8');
  await writeFile(driver.path, script.replace(JSON.stringify('AUDIT_PATH'), JSON.stringify(pidPath)));
  await assert.rejects(extractPdfPages(input, { binaryPath: driver.path, timeoutMs: 500, onPage() {} }), { code: 'timeout' });
  const pid = Number(await readFile(pidPath, 'utf8'));
  t.after(() => { try { process.kill(pid, 'SIGKILL'); } catch {} });
  let alive = true;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      process.kill(pid, 0);
      // Linux may keep an orphan's zombie entry briefly after SIGKILL.
      alive = !/^Z/u.test(execFileSync('ps', ['-o', 'stat=', '-p', String(pid)], { encoding: 'utf8' }).trim());
    } catch { alive = false; }
    if (!alive) break;
    await delay(50);
  }
  assert.equal(alive, false, 'owned descendant must be terminated');
  const audit = JSON.parse(await readFile(driver.audit, 'utf8'));
  await assert.rejects(access(audit.path), { code: 'ENOENT' });
});
