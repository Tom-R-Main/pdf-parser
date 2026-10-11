import assert from 'node:assert/strict';
import test from 'node:test';
import { access, readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractPdfDocument, extractPdfPages, locateSourceRange, parseArtifactJsonl, getPageGeometry, mapPdfBBoxToDisplay, mapDisplayBBoxToPdf } from './index.mjs';

const binaryPath = fileURLToPath(new URL('../../zig-out/bin/pdf-parser', import.meta.url));
const fixtureRoot = new URL('../../benchmark/eval/vector_routing/', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('manifest.json', fixtureRoot), 'utf8'));
let available = true;
try { await access(binaryPath, constants.X_OK); } catch { available = false; }
const toolAvailable = name => {
  try { execFileSync(name, [name === 'pdftoppm' ? '-v' : '--version'], { stdio: 'ignore', timeout: 5000 }); return true; } catch { return false; }
};
const rasterAvailable = toolAvailable('pdftoppm');
const ocrAvailable = toolAvailable('tesseract');
const fixture = name => readFile(new URL(`${name}.pdf`, fixtureRoot));
const fixtureInfo = name => manifest.fixtures.find(item => item.id === name);
const vectorRoutes = records => records.filter(record => record.record_type === 'route_trace' && record.trace_kind === 'region_route' && record.reasons.includes('unexplained_vector'));
const pageRoutes = records => records.filter(record => record.record_type === 'route_trace' && record.trace_kind === 'page_route');
const ocrAttempts = records => records.filter(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr');

function assertNative(document, name) {
  for (const expected of fixtureInfo(name).native_text) assert.ok(document.sourceText.includes(expected), `${name}: missing ${expected}`);
}

function assertLocated(document, phrase) {
  const start = document.sourceText.indexOf(phrase);
  assert.ok(start >= 0, document.sourceText);
  assert.ok(document.chunks.some(chunk => chunk.content.includes(phrase)), `missing chunk: ${phrase}`);
  const locator = locateSourceRange(document, start, start + phrase.length, { sourceTextSha256: document.sourceTextSha256 });
  assert.ok(locator.segments.some(segment => segment.sourceSpanId && segment.bbox));
  for (const segment of locator.segments.filter(segment => segment.sourceSpanId)) {
    const span = document.spans.find(item => item.span_id === segment.sourceSpanId);
    assert.equal(document.sourceText.slice(segment.start, segment.end), span.text.slice(segment.sourceStart, segment.sourceEnd));
    assert.equal(segment.pageIndex, span.page_index);
  }
}

function assertVectorEvidence(route) {
  const evidence = route.vector_evidence;
  assert.ok(evidence, route.route_trace_id);
  assert.equal(evidence.decision, 'unexplained_vector');
  for (const key of ['shape_count', 'segment_count', 'subpath_count']) assert.ok(Number.isInteger(evidence[key]) && evidence[key] > 0, key);
  assert.ok(evidence.native_coverage >= 0 && evidence.native_coverage <= 1);
  assert.ok(Number.isInteger(route.region_index));
  assert.ok(route.bbox.x0 < route.bbox.x1 && route.bbox.y0 < route.bbox.y1);
}

async function cliRecords(t, name, flags = [], format = 'artifact-jsonl') {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-vector-cli-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const input = join(directory, 'input.pdf');
  const bytes = await fixture(name);
  await writeFile(input, bytes);
  const raw = execFileSync(binaryPath, ['extract-adaptive', '--input', input, '--format', format, ...flags], {
    encoding: 'utf8', timeout: 45000, maxBuffer: 10 * 1024 * 1024,
  });
  const records = raw.trim().split('\n').map(JSON.parse);
  assert.equal(records[0].schema_version, '0.19.0');
  const document = format === 'artifact-jsonl' ? parseArtifactJsonl(raw, { inputSha256: createHash('sha256').update(bytes).digest('hex') }) : null;
  return { bytes, raw, records, document };
}

async function tools(t, mode = 'success', extraFlags = []) {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-vector-engine-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const engine = join(directory, 'engine.mjs');
  const log = join(directory, 'calls.txt');
  await writeFile(engine, `#!/usr/bin/env node
import { readFileSync, appendFileSync } from 'node:fs';
appendFileSync(${JSON.stringify(log)}, process.argv[2] + '\\n');
${mode === 'failed' ? 'process.exit(7);' : ''}
const image = readFileSync(process.argv[2]);
const width = image.readUInt32BE(16), height = image.readUInt32BE(20);
if (width < 6 || height < 6) process.exit(8);
process.stdout.write('level\\tpage_num\\tblock_num\\tpar_num\\tline_num\\tword_num\\tleft\\ttop\\twidth\\theight\\tconf\\ttext\\n');
process.stdout.write('5\\t1\\t1\\t1\\t1\\t1\\t2\\t2\\t' + ${mode === 'disjoint' ? '1' : 'Math.min(80,width-4)'} + '\\t' + ${mode === 'disjoint' ? '1' : 'Math.min(14,height-4)'} + '\\t99\\tVECTOR EVIDENCE\\n');
`, { mode: 0o700 });
  const wrapper = join(directory, 'parser.mjs');
  const executable = mode === 'unavailable' ? join(directory, 'missing-engine') : engine;
  const flags = ['--ocr-executable', executable, '--ocr-policy', 'single', '--ocr-dpi', '144', ...extraFlags];
  await writeFile(wrapper, `#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
const result = spawnSync(${JSON.stringify(binaryPath)}, [...process.argv.slice(2), ...${JSON.stringify(flags)}], { maxBuffer: 10*1024*1024, timeout: 45000 });
if (result.error) { process.stderr.write(String(result.error)); process.exit(9); }
process.stdout.write(result.stdout); process.stderr.write(result.stderr); process.exitCode = result.status ?? 9;
`, { mode: 0o700 });
  return { binaryPath: wrapper, engine, log };
}

test('vector fixtures retain real curved glyph paths and reproducible bounded input identities', async () => {
  assert.equal(manifest.font_program_embedded, false);
  assert.match(await readFile(new URL(manifest.font_license_file, fixtureRoot), 'utf8'), /Copyright \(c\) 2003 by Bitstream/u);
  assert.equal(manifest.fixtures.length, 23);
  for (const item of manifest.fixtures) {
    const bytes = await fixture(item.id);
    assert.equal(bytes.length, item.bytes);
    assert.ok(bytes.length <= 100000, item.id);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), item.sha256);
    assert.ok(!bytes.toString('ascii').includes('/FontFile'), item.id);
  }
  const bytes = (await fixture('outlined-text')).toString('ascii');
  assert.match(bytes, / c\nh/u);
  assert.ok(!bytes.includes('(VECTOR EVIDENCE)'));
  assert.ok(!bytes.includes(' Tj'));
});

test('outlined text and mixed native paths emit bounded unresolved vector routes in both formats', { skip: !available }, async t => {
  for (const name of ['outlined-text', 'mixed-native-outlines', 'partial-native-clip', 'chart-labels', 'transformed-form', 'quarter-turn-outlines', 'rule-through-outlines', 'stroked-letterforms', 'compound-fill']) {
    for (const format of ['artifact-jsonl', 'stream-jsonl']) {
      const { records, document } = await cliRecords(t, name, ['--no-ocr'], format);
      const routes = vectorRoutes(records);
      assert.ok(routes.length > 0, `${name}/${format}: no vector route`);
      routes.forEach(assertVectorEvidence);
      const page = pageRoutes(records)[0];
      assert.ok(page.vector_evidence.shape_count > 0);
      assert.ok(page.vector_evidence.candidate_region_count > 0);
      assert.equal(page.vector_evidence.max_shapes, 512);
      assert.equal(page.vector_evidence.max_segments_per_path, 512);
      assert.equal(page.vector_evidence.max_operators, 100000);
      assert.equal(page.coverage.requested_recovery, true);
      assert.equal(page.coverage.completeness, 'unverified');
      if (document) assertNative(document, name);
    }
  }
});

test('rules highlights boxes borders logos and clipped-out shapes do not invent vector OCR routes', { skip: !available }, async t => {
  for (const name of ['thin-stroked-rule', 'thin-filled-rule', 'native-highlight', 'filled-box', 'border', 'single-logo', 'clipped-out']) {
    const { records, document } = await cliRecords(t, name, ['--no-ocr']);
    assert.equal(vectorRoutes(records).length, 0, name);
    assertNative(document, name);
    assert.ok(pageRoutes(records)[0].vector_evidence, name);
  }
});

test('dense graphics and fused panels expose conservative vector evidence without a completeness claim', { skip: !available }, async t => {
  for (const name of ['dense-graphics', 'fused-panel']) {
    const { records, document } = await cliRecords(t, name, ['--no-ocr']);
    const evidence = pageRoutes(records)[0].vector_evidence;
    assert.ok(evidence.shape_count > 0);
    assert.ok(evidence.ambiguous_shape_count > 0 || vectorRoutes(records).length > 0 || evidence.simple_graphic_count > 0);
    assert.equal(pageRoutes(records)[0].coverage.completeness, 'unverified');
    assertNative(document, name);
  }
});

test('non-axis-aligned Form clipping explicitly abstains from vector OCR', { skip: !available }, async t => {
  const { records, document } = await cliRecords(t, 'sheared-form', ['--no-ocr']);
  const evidence = pageRoutes(records)[0].vector_evidence;
  assert.equal(evidence.status, 'partial');
  assert.ok(evidence.unknown_count > 0);
  assert.ok(evidence.ambiguous_shape_count > 0);
  assert.equal(vectorRoutes(records).length, 0);
  assertNative(document, 'sheared-form');
  assert.equal(pageRoutes(records)[0].coverage.completeness, 'unverified');
});

test('native vector collection caps report limited evidence while preserving native text', { skip: !available }, async t => {
  for (const name of ['shape-cap', 'segment-cap']) {
    const { records, document } = await cliRecords(t, name, ['--no-ocr']);
    const evidence = pageRoutes(records)[0].vector_evidence;
    assert.equal(evidence.status, 'limited', name);
    assert.ok(evidence.shape_count <= evidence.max_shapes);
    assert.equal(pageRoutes(records)[0].coverage.completeness, 'unverified');
    assertNative(document, name);
  }
});

test('deterministic regional vector OCR binds routes attempts source text chunks and locators', { skip: !available || !rasterAvailable }, async t => {
  const fake = await tools(t);
  const bytes = await fixture('mixed-native-outlines');
  const document = await extractPdfDocument(bytes, { binaryPath: fake.binaryPath, enableOcr: true });
  assertNative(document, 'mixed-native-outlines');
  assertLocated(document, 'VECTOR EVIDENCE');
  const routes = vectorRoutes(document.records);
  assert.ok(routes.length > 0);
  const attempts = ocrAttempts(document.records).filter(attempt => attempt.selected);
  assert.ok(attempts.length > 0);
  for (const attempt of attempts) {
    const route = routes.find(item => item.region_index === attempt.region_index);
    assert.ok(route);
    assert.ok(route.specialist_request_ids.includes(attempt.request_id));
    assert.equal(attempt.page_index, route.page_index);
    assert.ok(attempt.crop.image_byte_length > 24);
    assert.match(attempt.crop.image_sha256, /^[a-f0-9]{64}$/u);
  }
  const pages = [];
  const receipt = await extractPdfPages(bytes, { binaryPath: fake.binaryPath, enableOcr: true, onPage: page => pages.push(page) });
  assert.equal(receipt.complete, true);
  assert.equal(receipt.schemaVersion, '0.19.0');
  assertNative(pages[0], 'mixed-native-outlines');
  assertLocated(pages[0], 'VECTOR EVIDENCE');
  const cropPaths = (await readFile(fake.log, 'utf8')).trim().split('\n');
  assert.ok(cropPaths.length >= 2);
  for (const path of cropPaths) await assert.rejects(access(path), { code: 'ENOENT' });
});

test('partially clipped native text cannot account for visible outlines painted after restore', { skip: !available || !rasterAvailable || !ocrAvailable }, async t => {
  const bytes = await fixture('partial-native-clip');
  const document = await extractPdfDocument(bytes, { binaryPath, enableOcr: true });
  assertNative(document, 'partial-native-clip');
  assertLocated(document, 'VECTOR EVIDENCE');
  const routes = vectorRoutes(document.records);
  assert.ok(routes.length > 0);
  assert.ok(routes.every(route => route.vector_evidence.native_coverage < 0.01));
  assert.ok(document.spans.some(span => span.text === 'VECTOR' && span.chosen_source === 'fresh_ocr'));
  const pages = [];
  await extractPdfPages(bytes, { binaryPath, enableOcr: true, onPage: page => pages.push(page) });
  assertNative(pages[0], 'partial-native-clip');
  assertLocated(pages[0], 'VECTOR EVIDENCE');
  assert.ok(pages[0].spans.some(span => span.text === 'VECTOR' && span.chosen_source === 'fresh_ocr'));
});

test('failed unavailable and pixel-refused vector OCR preserve native evidence and unresolved routes', { skip: !available || !rasterAvailable }, async t => {
  const bytes = await fixture('mixed-native-outlines');
  for (const mode of ['failed', 'unavailable', 'pixels']) {
    const fake = await tools(t, mode);
    const document = await extractPdfDocument(bytes, { binaryPath: fake.binaryPath, enableOcr: true, allowPartial: true,
      ...(mode === 'pixels' ? { ocrLimits: { maxImagePixels: 1 } } : {}) });
    assertNative(document, 'mixed-native-outlines');
    assert.ok(!document.sourceText.includes('VECTOR EVIDENCE'));
    assert.ok(vectorRoutes(document.records).length > 0);
    assert.equal(document.pageOutcomes[0].completeness, 'unverified');
    assert.notEqual(document.pageOutcomes[0].status, 'recovered');
    const attempts = ocrAttempts(document.records);
    assert.ok(attempts.length > 0);
    assert.ok(attempts.every(attempt => !attempt.selected));
    if (mode === 'pixels') {
      assert.ok(attempts.some(attempt => attempt.errors.some(error => error.code === 'rasterizer_pixel_limit')));
      await assert.rejects(access(fake.log), { code: 'ENOENT' });
    }
  }
});

test('repeated vector crops have global identities and preserve every quota refusal', { skip: !available || !rasterAvailable }, async t => {
  const fake = await tools(t);
  const bytes = await fixture('repeated-multipage');
  for (const limits of [{ maxRegionsPerPage: 1 }, { maxAttemptsPerPage: 1 }]) {
    const document = await extractPdfDocument(bytes, { binaryPath: fake.binaryPath, enableOcr: true, allowPartial: true, ocrLimits: limits });
    const routes = vectorRoutes(document.records);
    assert.ok(routes.length >= 4);
    assert.equal(new Set(routes.map(route => route.region_index)).size, routes.length);
    const attempts = ocrAttempts(document.records);
    assert.equal(new Set(attempts.map(attempt => attempt.attempt_id)).size, attempts.length);
    for (const route of routes) assert.ok(attempts.some(attempt => attempt.region_index === route.region_index), `missing attempt for ${route.route_trace_id}`);
    const expected = limits.maxRegionsPerPage ? 'ocr_region_limit' : 'ocr_attempt_limit';
    assert.ok(attempts.some(attempt => attempt.attempt_status === 'not_invoked' && [...attempt.errors, ...attempt.warnings].some(error => error.code === expected)));
    assert.ok(document.pageOutcomes.every(outcome => outcome.completeness === 'unverified' && outcome.status !== 'recovered'));
    assertNative(document, 'repeated-multipage');
  }
  const pages = [];
  await extractPdfPages(bytes, { binaryPath: fake.binaryPath, enableOcr: true, onPage: page => pages.push(page) });
  assert.equal(pages.length, 2);
  const attempts = pages.flatMap(page => ocrAttempts(page.records));
  assert.equal(new Set(attempts.map(attempt => attempt.attempt_id)).size, attempts.length);
  for (const page of pages) assertLocated(page, 'VECTOR EVIDENCE');
});

test('overlapping bitmap and vector candidates share one regional OCR recovery', { skip: !available || !rasterAvailable }, async t => {
  const fake = await tools(t);
  const document = await extractPdfDocument(await fixture('image-overlap'), { binaryPath: fake.binaryPath, enableOcr: true });
  const selected = ocrAttempts(document.records).filter(attempt => attempt.selected);
  assert.equal(selected.length, 1);
  assert.equal(vectorRoutes(document.records).length, 1);
  assertLocated(document, 'VECTOR EVIDENCE');
  assertNative(document, 'image-overlap');
});

test('OCR text outside a vector candidate cannot recover its reused bitmap route', { skip: !available || !rasterAvailable }, async t => {
  const fake = await tools(t, 'disjoint');
  const bytes = await fixture('image-overlap');
  const batch = await extractPdfDocument(bytes, { binaryPath: fake.binaryPath, enableOcr: true });
  const pages = [];
  await extractPdfPages(bytes, { binaryPath: fake.binaryPath, enableOcr: true, onPage: page => pages.push(page) });
  for (const records of [batch.records, pages[0].records]) {
    assert.equal(ocrAttempts(records).filter(attempt => attempt.selected).length, 1);
    const routes = vectorRoutes(records);
    assert.equal(routes.length, 1);
    assert.equal(routes[0].coverage.status, 'recovery_required');
    assert.equal(routes[0].coverage.unresolved_region_count, 1);
    assert.equal(routes[0].coverage.completeness, 'unverified');
  }
  assert.equal(batch.pageOutcomes[0].status, 'recovery_required');
});

test('actual Tesseract recovers path-only and mixed outlined text in both public SDK formats', { skip: !available || !rasterAvailable || !ocrAvailable }, async () => {
  for (const name of ['outlined-text', 'mixed-native-outlines', 'transformed-form', 'quarter-turn-outlines', 'compound-fill']) {
    const bytes = await fixture(name);
    const document = await extractPdfDocument(bytes, { binaryPath, enableOcr: true });
    assertNative(document, name);
    assertLocated(document, 'VECTOR EVIDENCE');
    assert.ok(vectorRoutes(document.records).length > 0);
    assert.ok(ocrAttempts(document.records).some(attempt => attempt.selected && Number.isInteger(attempt.region_index)));
    if (name === 'quarter-turn-outlines') {
      const geometry = getPageGeometry(document, 0);
      assert.equal(geometry.rotation_degrees, 90);
      const word = document.spans.find(span => span.text === 'VECTOR' && span.chosen_source === 'fresh_ocr');
      assert.ok(word);
      const expected = fixtureInfo(name).outlined_bboxes[0];
      assert.ok(word.bbox.x0 >= expected[0] - 3 && word.bbox.x1 <= expected[2] + 3);
      assert.ok(word.bbox.y0 >= expected[1] - 3 && word.bbox.y1 <= expected[3] + 3);
      assert.ok(word.bbox.y1 - word.bbox.y0 > word.bbox.x1 - word.bbox.x0);
      const display = mapPdfBBoxToDisplay(word.bbox, geometry, { scale: 1 });
      assert.ok(display.x1 - display.x0 > display.y1 - display.y0);
      const roundtrip = mapDisplayBBoxToPdf(display, geometry, { scale: 1 });
      for (const key of ['x0', 'y0', 'x1', 'y1']) assert.ok(Math.abs(roundtrip[key] - word.bbox[key]) < 0.01);
    }
    const pages = [];
    const receipt = await extractPdfPages(bytes, { binaryPath, enableOcr: true, onPage: page => pages.push(page) });
    assert.equal(receipt.complete, true);
    assertNative(pages[0], name);
    assertLocated(pages[0], 'VECTOR EVIDENCE');
  }
});
