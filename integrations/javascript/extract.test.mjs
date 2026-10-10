import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile, rm, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { extractPdfDocument, extractPdfText, parseArtifactJsonl, projectPromptText, locateSourceRange, utf8BoundaryMap } from './extract.mjs';

const bytes = Buffer.from('%PDF-fake');
const sha = (value) => createHash('sha256').update(value).digest('hex');
const inputSha256 = sha(bytes);
const bbox = { x0: 10, y0: 20, x1: 60, y1: 30 };
function fixture() {
  const common = (type, id, refs = {}) => ({ schema_name: type, schema_version: '0.14.0', record_type: type,
    document_id: 'doc', source_id: inputSha256,
    provenance: { document_id: 'doc', source_id: inputSha256, input_sha256: inputSha256, artifact_id: id,
      span_ids: [], block_ids: [], chunk_ids: [], ...refs } });
  const view = (id, kind, text) => ({ text_view_id: `${id}:text`, kind, offset_unit: 'utf8_byte', range_convention: 'half_open', normalization: 'none', text_sha256: sha(text) });
  const texts = ['A 😀  B', 'Next'];
  const spans = texts.map((text, i) => ({ ...common('span', `span-${i}`, { span_ids: [`span-${i}`], block_ids: [`block-${i}`] }), span_id: `span-${i}`, text, bbox, page_index: 0,
    text_view: view(`span-${i}`, 'reconciled_span', text) }));
  const blocks = texts.map((text, i) => ({ ...common('block', `block-${i}`, { span_ids: [`span-${i}`], block_ids: [`block-${i}`] }), block_id: `block-${i}`, text, bbox, page_index: 0,
    text_view: view(`block-${i}`, 'reconciled_block', text), source_map: [{ text_start_byte: 0, text_end_byte: Buffer.byteLength(text), source_span_id: `span-${i}`, source_start_byte: 0, source_end_byte: Buffer.byteLength(text) }] }));
  const content = texts.join('\n\n');
  const firstLength = Buffer.byteLength(texts[0]);
  const chunk = { ...common('rag_chunk', 'chunk-0', { span_ids: ['span-0', 'span-1'], block_ids: ['block-0', 'block-1'], chunk_ids: ['chunk-0'] }), chunk_id: 'chunk-0', content,
    page_start: 0, page_end: 0, source_span_ids: ['span-0', 'span-1'], source_block_ids: ['block-0', 'block-1'],
    text_view: view('chunk-0', 'rag_chunk', content), source_map: [
      { text_start_byte: 0, text_end_byte: firstLength, source_block_id: 'block-0', source_start_byte: 0, source_end_byte: firstLength },
      { text_start_byte: firstLength, text_end_byte: firstLength + 2, source_block_id: null, source_start_byte: null, source_end_byte: null },
      { text_start_byte: firstLength + 2, text_end_byte: Buffer.byteLength(content), source_block_id: 'block-1', source_start_byte: 0, source_end_byte: Buffer.byteLength(texts[1]) },
    ] };
  return [{ ...common('document_manifest', 'document_manifest'), input_sha256: inputSha256, page_count: 1,
    text_contract: { offset_unit: 'utf8_byte', range_convention: 'half_open', page_index_base: 0,
      geometry: { coordinate_space: 'pdf_user_space', unit: 'point', highlight_precision: 'span_bbox', display_transform: null } },
    artifact_counts: { spans: 2, blocks: 2, rag_chunks: 1 } }, ...spans, ...blocks, chunk];
}
const serialize = (records) => records.map((record) => JSON.stringify(record)).join('\n') + '\n';
const parse = (records) => parseArtifactJsonl(serialize(records), { inputSha256 });

function currentFixture() {
  const records = fixture();
  for (const record of records) record.schema_version = '0.15.0';
  for (const span of records.filter(record => record.record_type === 'span')) span.reconciled_block_id = span.provenance.block_ids[0];
  records[0].artifact_counts.tables = 1;
  records[0].artifact_counts.route_traces = 1;
  const envelope = (type, id) => ({ ...records[0], schema_name: type, record_type: type,
    provenance: { ...records[0].provenance, artifact_id: id } });
  records.push({ ...envelope('table', 'table-0'), page_index: 0, source_span_ids: ['span-0'],
    reconciled_block_ids: ['block-0'], rows: [{ cells: [{ page_index: 0, source_span_ids: ['span-0'], reconciled_block_ids: ['block-0'] }] }] });
  records.push({ ...envelope('route_trace', 'route-page-0'), trace_kind: 'page_route', page_index: 0,
    coverage: { status: 'text_available', completeness: 'unverified', native_span_count: 2,
      recognized_span_count: 0, requested_recovery: false, recovery_state: 'not_required', unresolved_region_count: 0 } });
  return records;
}

function paintFixture() {
  const records = currentFixture();
  for (const record of records) record.schema_version = '0.16.0';
  for (const span of records.filter(record => record.record_type === 'span')) span.paint = {
    rendering_mode: 0, paint_state: 'painting', clip_state: 'unclipped', clip_bbox: null,
  };
  Object.assign(records[7].coverage, { non_painting_span_count: 0, clipped_out_span_count: 0, uncertain_paint_span_count: 0 });
  const envelope = (type, id) => ({ schema_name: type, schema_version: '0.16.0', record_type: type,
    document_id: 'doc', source_id: inputSha256, provenance: { ...records[0].provenance, artifact_id: id } });
  Object.assign(records[0].artifact_counts, { specialist_requests: 1, specialist_attempts: 1, specialist_responses: 1 });
  records.push({ ...envelope('specialist_request', 'ocr-request'), request_id: 'ocr-request', page_index: 0, region_index: 0, requested_kind: 'ocr' });
  records.push({ ...envelope('specialist_attempt', 'ocr-attempt'), attempt_id: 'ocr-attempt', request_id: 'ocr-request', page_index: 0, region_index: 0,
    specialist_kind: 'ocr', attempt_status: 'completed', selected: true,
    config: { max_image_pixels: 100, max_image_bytes: 1024, max_regions_per_page: 1, max_attempts_per_page: 1 },
    crop: { bbox, dpi: 200, pixel_width: 10, pixel_height: 10, image_sha256: 'a'.repeat(64), image_byte_length: 100 } });
  records.push({ ...envelope('specialist_response', 'ocr-response'), response_id: 'ocr-response', request_id: 'ocr-request', page_index: 0, region_index: 0,
    specialist_kind: 'ocr', status: 'completed', attempt_count: 1, selected_attempt_id: 'ocr-attempt' });
  return records;
}

function scopeFixture() {
  const records = paintFixture();
  for (const record of records) record.schema_version = '0.17.0';
  for (const span of records.filter(record => record.record_type === 'span')) span.content_scope = {
    page_index: span.page_index, stream_object_num: null, stream_generation: 0, invocation_index: 0,
  };
  return records;
}

test('content scopes retain page roots and repeated Form identities', () => {
  const records = scopeFixture();
  records[1].content_scope = { page_index: 0, stream_object_num: 42, stream_generation: 2, invocation_index: 1 };
  records[2].content_scope = { ...records[1].content_scope, invocation_index: 2 };
  assert.equal(parse(records).spans[1].content_scope.invocation_index, 2);
});
for (const [name, mutate] of [
  ['missing scope', r => { delete r[1].content_scope; }],
  ['wrong page', r => { r[1].content_scope.page_index = 1; }],
  ['page invocation', r => { r[1].content_scope.invocation_index = 1; }],
  ['Form without invocation', r => { r[1].content_scope.stream_object_num = 42; }],
  ['bad generation', r => { r[1].content_scope.stream_generation = 65536; }],
  ['forged scope context', r => { r[8].spans = [{ span_id: 'span-0', text: r[1].text, bbox, paint: r[1].paint,
    content_scope: { ...r[1].content_scope, stream_object_num: 42, invocation_index: 1 } }]; }],
]) test(`scope contract rejects ${name}`, () => {
  const records = scopeFixture();
  mutate(records);
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('paint and crop evidence remain separate from visual completeness', () => {
  const document = parse(paintFixture());
  assert.equal(document.spans[0].paint.paint_state, 'painting');
  assert.equal(document.pageOutcomes[0].completeness, 'unverified');
});

test('OCR response can report a failed retry while retaining an earlier completed winner', () => {
  const records = paintFixture();
  const retry = structuredClone(records[9]);
  retry.attempt_id = retry.provenance.artifact_id = 'ocr-retry';
  retry.attempt_status = 'failed';
  retry.selected = false;
  records.splice(10, 0, retry);
  records[0].artifact_counts.specialist_attempts = 2;
  records[11].attempt_count = 2;
  records[11].status = 'failed';
  assert.equal(parse(records).records.at(-1).selected_attempt_id, 'ocr-attempt');
});

test('completed OCR results require a completed selected OCR attempt', () => {
  const records = paintFixture();
  const result = structuredClone(records[10]);
  result.record_type = result.schema_name = 'specialist_result';
  result.specialist_result_id = result.provenance.artifact_id = 'ocr-result';
  records.push(result);
  records[0].artifact_counts.specialist_results = 1;
  assert.ok(parse(records));
  records[9].attempt_status = 'empty';
  records[10].status = 'empty';
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('OCR responses preserve legacy failed summary with detailed timeout and invalid-output attempts', () => {
  for (const status of ['timeout', 'invalid_output']) {
    const records = paintFixture();
    records[9].attempt_status = status;
    records[9].selected = false;
    records[10].status = 'failed';
    records[10].selected_attempt_id = null;
    assert.ok(parse(records));
  }
});
for (const [name, mutate] of [
  ['missing paint', r => { delete r[1].paint; }],
  ['unknown rendering mode', r => { r[1].paint.rendering_mode = 8; }],
  ['nonpainting mode called painting', r => { r[1].paint.rendering_mode = 3; }],
  ['unbounded inside clip', r => { r[1].paint.clip_state = 'inside'; }],
  ['invalid clip geometry', r => { r[1].paint.clip_state = 'outside'; r[1].paint.clip_bbox = { ...bbox, x0: 100 }; }],
  ['missing paint counts', r => { delete r[7].coverage.non_painting_span_count; }],
  ['crop without request', r => { r[9].request_id = 'unknown'; }],
  ['crop on wrong scope', r => { r[9].region_index = 1; }],
  ['crop exceeds pixel budget', r => { r[9].crop.pixel_width = 11; }],
  ['crop exceeds byte budget', r => { r[9].crop.image_byte_length = 1025; }],
  ['crop without hash', r => { r[9].crop.image_sha256 = null; }],
  ['crop missing budgets', r => { delete r[9].config.max_image_pixels; }],
  ['unknown selected attempt', r => { r[10].selected_attempt_id = 'unknown'; }],
  ['unselected chosen attempt', r => { r[9].selected = false; }],
  ['selected wrong specialist', r => { r[9].specialist_kind = 'formula'; }],
  ['selected failed attempt', r => { r[9].attempt_status = 'failed'; }],
  ['nonboolean selection', r => { r[9].selected = 'true'; }],
  ['unknown attempt status', r => { r[9].attempt_status = 'made_up'; }],
  ['wrong response status', r => { r[10].status = 'failed'; }],
  ['wrong response count', r => { r[10].attempt_count = 2; }],
  ['foreign specialist span', r => { r[8].span_ids = ['span-999']; }],
  ['forged specialist span context', r => { r[8].spans = [{ span_id: 'span-0', text: 'forged', bbox }]; }],
  ['forged specialist paint context', r => { r[8].spans = [{ span_id: 'span-0', text: r[1].text, bbox, paint: { ...r[1].paint, paint_state: 'unknown' } }]; }],
  ['foreign specialist block', r => { r[8].block_ids = ['block-999']; }],
]) test(`paint contract rejects ${name}`, () => {
  const records = paintFixture();
  mutate(records);
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('specialist context matches paint and tolerates only declared bbox rounding', () => {
  const records = paintFixture();
  const context = { span_id: 'span-0', text: records[1].text, bbox: { ...bbox, x0: bbox.x0 + 0.004 }, paint: structuredClone(records[1].paint) };
  records[8].spans = [context];
  records[8].span_ids = ['span-0'];
  assert.ok(parse(records));
  context.bbox.x0 = bbox.x0 + 0.006;
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('current schema exposes authoritative table ownership and unverified page outcomes', () => {
  const document = parse(currentFixture());
  assert.deepEqual(document.tables[0].reconciled_block_ids, ['block-0']);
  assert.equal(document.pageOutcomes[0].status, 'text_available');
  assert.equal(document.pageOutcomes[0].completeness, 'unverified');
});

test('legacy chunk label remains metadata when caller source identity is null', () => {
  const records = fixture();
  for (const record of records) { record.source_id = null; record.provenance.source_id = null; }
  records[5].source_id = 'document';
  const document = parseArtifactJsonl(serialize(records), { inputSha256, expectedSourceId: null });
  assert.equal(document.manifest.source_id, null);
  assert.equal(document.chunks[0].source_id, 'document');
  records[0].source_id = inputSha256;
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('malformed table rows remain protocol errors through the subprocess adapter', async (t) => {
  const records = currentFixture();
  records[6].rows = [null];
  const { binaryPath } = await fakeParser(t, `process.stdout.write(${JSON.stringify(serialize(records))});`);
  await assert.rejects(extractPdfDocument(bytes, { binaryPath }), { code: 'protocol' });
});

test('batch forwards explicit OCR budgets and partial-result policy', async (t) => {
  const { dir, binaryPath } = await fakeParser(t, `import {writeFileSync} from 'node:fs';
    writeFileSync(new URL('./args.json',import.meta.url),JSON.stringify(process.argv.slice(2)));
    process.stdout.write(${JSON.stringify(serialize(fixture()))});`);
  await extractPdfDocument(bytes, { binaryPath, allowPartial: true, ocrLimits: { maxImagePixels: 1000, maxImageBytes: 2048, maxRegionsPerPage: 2, maxAttemptsPerPage: 3 } });
  const args = JSON.parse(await readFile(join(dir, 'args.json'), 'utf8'));
  for (const [flag, value] of [['--ocr-max-image-pixels', '1000'], ['--ocr-max-image-bytes', '2048'], ['--ocr-max-regions', '2'], ['--ocr-max-attempts', '3']]) assert.equal(args[args.indexOf(flag) + 1], value);
  assert.ok(args.includes('--allow-partial'));
  for (const limits of [{ maxImagePixels: 0 }, { maxImageBytes: 1.5 }, { maxImagesPixels: 100 }]) await assert.rejects(extractPdfDocument(bytes, { binaryPath, ocrLimits: limits }), RangeError);
  await assert.rejects(extractPdfDocument(bytes, { binaryPath, allowPartial: 'yes' }), TypeError);
});

for (const [name, mutate] of [
  ['unknown span owner', r => { r[1].reconciled_block_id = 'block-999'; }],
  ['wrong existing span owner', r => { r[1].reconciled_block_id = 'block-1'; }],
  ['null owned span', r => { r[1].reconciled_block_id = null; }],
  ['missing span owner', r => { delete r[1].reconciled_block_id; }],
  ['wrong span ownership provenance', r => { r[1].provenance.block_ids = ['block-1']; }],
  ['wrong span self provenance', r => { r[1].provenance.span_ids = ['span-1']; }],
  ['wrong table owner', r => { r[6].reconciled_block_ids = ['block-1']; }],
  ['missing table owner', r => { delete r[6].reconciled_block_ids; }],
  ['malformed table row', r => { r[6].rows = [null]; }],
  ['wrong cell owner', r => { r[6].rows[0].cells[0].reconciled_block_ids = ['block-1']; }],
  ['cross-page cell sources', r => { r[0].page_count = 2; r[6].rows[0].cells[0].page_index = 1; }],
  ['invented complete coverage', r => { r[7].coverage.completeness = 'complete'; }],
  ['missing coverage', r => { delete r[7].coverage; }],
  ['unknown recovery state', r => { r[7].coverage.recovery_state = 'successful'; }],
  ['invalid coverage count', r => { r[7].coverage.unresolved_region_count = -1; }],
  ['coverage outside document', r => { r[7].page_index = 999; }],
  ['contradictory recovery', r => { Object.assign(r[7].coverage, { status: 'recovered', recovery_state: 'failed' }); }],
  ['unrecognized successful recovery', r => { Object.assign(r[7].coverage, { status: 'recovered', requested_recovery: true, recovery_state: 'completed' }); }],
  ['successful recovery with unresolved regions', r => { Object.assign(r[7].coverage, { status: 'recovered', requested_recovery: true, recovery_state: 'completed', recognized_span_count: 1, unresolved_region_count: 1 }); }],
  ['cell on another valid page', r => {
    r[0].page_count = 2;
    r[2].page_index = 1;
    r[4].page_index = 1;
    r[5].page_end = 1;
    Object.assign(r[6].rows[0].cells[0], { page_index: 1, source_span_ids: ['span-1'], reconciled_block_ids: ['block-1'] });
  }],
]) test(`current schema rejects ${name}`, () => {
  const records = currentFixture();
  mutate(records);
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('rich projection preserves whitespace, Unicode, records and span geometry', () => {
  const document = parse(fixture());
  assert.equal(document.sourceText, 'A 😀  B\n\nNext');
  assert.equal(document.sourceTextSha256, sha(document.sourceText));
  assert.equal(document.pageCoverage, 'unverified');
  assert.equal(document.spans.length, 2);
  assert.equal(document.chunks[0].content, document.sourceText);
  assert.equal(document.sourceMap[0].end, 7);
  assert.deepEqual(document.sourceMap[1], { start: 7, end: 9, sourceBlockId: null, sourceSpanId: null, pageIndex: null, bbox: null, sourceStart: null, sourceEnd: null });
  assert.deepEqual(document.sourceMap[0].bbox, bbox);
  assert.deepEqual([...utf8BoundaryMap('A😀é')], [[0, 0], [1, 1], [5, 3], [7, 4]]);
});

test('prompt projection cannot split emoji or mutate authoritative source offsets', () => {
  const document = parse(fixture());
  const projection = projectPromptText(document, 3);
  assert.equal(projection.text, 'A ');
  assert.equal(projection.truncated, true);
  assert.equal(document.sourceText, 'A 😀  B\n\nNext');
  assert.equal(projection.sourceEnd, 2);
  assert.throws(() => projectPromptText(document, -1), RangeError);
});

test('range lookup clips UTF-16 span origins and preserves synthetic gaps', () => {
  const document = parse(fixture());
  const options = { sourceTextSha256: document.sourceTextSha256 };
  const result = locateSourceRange(document, 2, 10, options);
  assert.equal(result.segments[0].sourceStart, 2);
  assert.equal(result.segments[0].sourceEnd, 7);
  assert.equal(result.segments[1].bbox, null);
  assert.equal(result.segments[2].sourceEnd, 1);
  assert.throws(() => locateSourceRange(document, 3, 4, options), /UTF-16/);
  assert.throws(() => locateSourceRange(document, 0, 1, { sourceTextSha256: 'a'.repeat(64) }), /hash/);
  assert.throws(() => locateSourceRange(document, 0, 1), /hash/);
  document.sourceText += '!';
  assert.throws(() => locateSourceRange(document, 0, 1, options), /hash/);
});

const corruptions = [
  ['schema family', (r) => { r[0].schema_version = '0.13.0'; }],
  ['per-record version', (r) => { r[1].schema_version = '0.14.1'; }],
  ['manifest coordinate contract', (r) => { r[0].text_contract.geometry.coordinate_space = 'screen'; }],
  ['nonnumeric span geometry', (r) => { r[1].bbox = { x0: '10', y0: 20, x1: 60, y1: 30 }; }],
  ['inverted span geometry', (r) => { r[1].bbox = { x0: 60, y0: 20, x1: 10, y1: 30 }; }],
  ['missing span geometry', (r) => { delete r[1].bbox; }],
  ['manifest offset contract', (r) => { r[0].text_contract.offset_unit = 'utf16_code_unit'; }],
  ['declared route count', (r) => { r[0].artifact_counts.route_traces = 1; }],
  ['schema name', (r) => { r[1].schema_name = 'block'; }],
  ['input hash', (r) => { r[0].input_sha256 = 'f'.repeat(64); }],
  ['provenance', (r) => { r[1].provenance.input_sha256 = 'f'.repeat(64); }],
  ['source identity', (r) => { r[1].source_id = 'other'; }],
  ['missing source identity', (r) => { for (const record of r) { delete record.source_id; delete record.provenance.source_id; } }],
  ['invalid source identity type', (r) => { for (const record of r) { record.source_id = 42; record.provenance.source_id = 42; } }],
  ['duplicate artifact', (r) => { r.push(r[1]); }],
  ['duplicate manifest', (r) => { r.push({ ...r[0], provenance: { ...r[0].provenance, artifact_id: 'other' } }); }],
  ['missing first manifest', (r) => { r.shift(); }],
  ['truncated batch', (r) => { r.pop(); }],
  ['text hash', (r) => { r[1].text += '!'; }],
  ['normalization contract', (r) => { r[1].text_view.normalization = 'whitespace'; }],
  ['UTF-8 boundary inside emoji', (r) => { r[3].source_map[0].source_end_byte = 3; }],
  ['missing coverage', (r) => { r[3].source_map = []; }],
  ['unordered coverage', (r) => { r[3].source_map[0].text_start_byte = 1; }],
  ['unresolved span', (r) => { r[3].source_map[0].source_span_id = 'span-100'; }],
  ['unresolved chunk source', (r) => { r[5].source_block_ids.push('block-100'); }],
  ['unresolved provenance link', (r) => { r[3].provenance.span_ids.push('span-100'); }],
  ['synthetic source offsets', (r) => { r[5].source_map[1].source_start_byte = 0; }],
  ['synthetic forged text', (r) => { r[3].source_map[0].source_span_id = null; r[3].source_map[0].source_start_byte = null; r[3].source_map[0].source_end_byte = null; }],
  ['cross-page span', (r) => { r[0].page_count = 2; r[1].page_index = 1; }],
  ['cross-page block', (r) => { r[0].page_count = 2; r[1].page_index = 1; r[3].page_index = 1; }],
  ['chunk source identity omission', (r) => { r[5].source_span_ids.pop(); }],
  ['chunk source identity duplication', (r) => { r[5].source_block_ids.push('block-0'); }],
  ['block provenance omission', (r) => { r[3].provenance.span_ids = []; }],
  ['chunk provenance omission', (r) => { r[5].provenance.span_ids = []; }],
  ['slice mismatch', (r) => { r[3].source_map[0].source_span_id = 'span-1'; }],
  ['invalid page', (r) => { r[1].page_index = 2; }],
];
for (const [name, change] of corruptions) test(`rejects ${name}`, () => {
  const records = fixture();
  change(records);
  assert.throws(() => parse(records), { code: 'protocol' });
});
test('rejects malformed JSON, empty input, blank lines and unpaired surrogates', () => {
  for (const text of ['{', '', serialize(fixture()) + '\n']) assert.throws(() => parseArtifactJsonl(text, { inputSha256 }), { code: 'protocol' });
  assert.throws(() => utf8BoundaryMap('\ud800'), { code: 'protocol' });
});
for (const [type, idField, countField] of [
  ['specialist_request', 'request_id', 'specialist_requests'],
  ['specialist_attempt', 'attempt_id', 'specialist_attempts'],
  ['specialist_response', 'response_id', 'specialist_responses'],
  ['specialist_result', 'specialist_result_id', 'specialist_results'],
]) {
  const specialistFixture = () => {
    const records = fixture();
    records[0].artifact_counts[countField] = 2;
    for (let i = 0; i < 2; i++) records.push({ schema_name: type, schema_version: '0.14.0', record_type: type,
      document_id: 'doc', source_id: inputSha256, [idField]: `${type}-${i}`,
      provenance: { ...records[0].provenance, artifact_id: type } });
    return records;
  };
  test(`${type} retains repeated compatibility ids with unique record ids`, () => {
    assert.equal(parse(specialistFixture()).records.filter((record) => record.record_type === type).length, 2);
  });
  test(`${type} rejects duplicated or missing actual record identity`, () => {
    const records = specialistFixture();
    records.at(-1)[idField] = records.at(-2)[idField];
    assert.throws(() => parse(records), { code: 'protocol' });
    delete records.at(-1)[idField];
    assert.throws(() => parse(records), { code: 'protocol' });
  });
}
test('legacy unresolved table block refs are diagnostic metadata, never locator inputs', () => {
  const records = fixture();
  records[0].artifact_counts.tables = 1;
  records.push({ schema_name: 'table', schema_version: '0.14.0', record_type: 'table',
    document_id: 'doc', source_id: inputSha256,
    provenance: { ...records[0].provenance, artifact_id: 'table-0', block_ids: ['block-0', 'block-99'] } });
  const document = parse(records);
  assert.deepEqual(document.unresolvedProvenanceLinks, [{ recordType: 'table', artifactId: 'table-0', field: 'block_ids', id: 'block-99' }]);
  assert.equal(document.records.at(-1).provenance.block_ids[1], 'block-99');
  assert.ok(locateSourceRange(document, 0, document.sourceText.length, { sourceTextSha256: document.sourceTextSha256 }).segments.every((segment) => segment.sourceBlockId !== 'block-99'));
  records[3].provenance.block_ids.push('block-99');
  assert.throws(() => parse(records), { code: 'protocol' });
  records[3].provenance.block_ids.pop();
  records.at(-1).provenance.span_ids.push('span-99');
  assert.throws(() => parse(records), { code: 'protocol' });
});

async function fakeParser(t, body) {
  const dir = await mkdtemp(join(tmpdir(), 'pdf-parser-adapter-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const binaryPath = join(dir, 'parser.mjs');
  await writeFile(binaryPath, `#!${process.execPath}\n${body}\n`, { mode: 0o700 });
  return { dir, binaryPath };
}
test('actual subprocess uses private input, bounded adapter protocol and cleans scratch files', async (t) => {
  const { dir, binaryPath } = await fakeParser(t, `import {writeFileSync,statSync} from 'node:fs';
    const input=process.argv[process.argv.indexOf('--input')+1];
    writeFileSync(new URL('./audit.json',import.meta.url),JSON.stringify({input,args:process.argv.slice(2),mode:statSync(input).mode&511}));
    process.stdout.write(${JSON.stringify(serialize(fixture()))});`);
  const document = await extractPdfDocument(bytes, { binaryPath });
  assert.equal(document.sourceText, 'A 😀  B\n\nNext');
  const audit = JSON.parse(await readFile(join(dir, 'audit.json'), 'utf8'));
  assert.equal(audit.mode, 0o600);
  assert.ok(audit.args.includes('--no-ocr'));
  assert.ok(audit.args.includes(inputSha256));
  await assert.rejects(access(audit.input), { code: 'ENOENT' });
  assert.equal(await extractPdfText(bytes, { binaryPath }), document.sourceText);
});

test('validates the source identity selected by the caller and adapter', async (t) => {
  const records = fixture();
  for (const record of records) { record.source_id = 'other'; record.provenance.source_id = 'other'; }
  assert.throws(() => parseArtifactJsonl(serialize(records), { inputSha256, expectedSourceId: inputSha256 }), /source identity/);
  const { binaryPath } = await fakeParser(t, `process.stdout.write(${JSON.stringify(serialize(records))});`);
  await assert.rejects(extractPdfDocument(bytes, { binaryPath }), { code: 'protocol' });
  const nullable = fixture();
  for (const record of nullable) { record.source_id = null; record.provenance.source_id = null; }
  assert.equal(parseArtifactJsonl(serialize(nullable), { inputSha256, expectedSourceId: null }).manifest.source_id, null);
});

for (const reason of ['timeout', 'aborted']) test(`bounds ${reason} and cleans scratch when a wrapper leaves inherited descendant pipes`, {
  skip: process.platform === 'win32' ? 'POSIX process-group regression' : false,
}, async (t) => {
  const { dir, binaryPath } = await fakeParser(t, `import { spawn } from 'node:child_process';
    import { writeFileSync } from 'node:fs';
    const input = process.argv[process.argv.indexOf('--input') + 1];
    const descendant = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 3000)'], { stdio: 'inherit' });
    writeFileSync(new URL('./descendant.json', import.meta.url), JSON.stringify({ pid: descendant.pid, input }));
    setInterval(() => {}, 1000);`);
  const controller = new AbortController();
  const started = performance.now();
  const pending = extractPdfDocument(bytes, { binaryPath, timeoutMs: reason === 'timeout' ? 1500 : 5000, signal: controller.signal });
  // Observe descendant creation before cancellation; startup latency must not
  // turn this regression into a test that kills the wrapper before it forks.
  let audit;
  while (!audit && performance.now() - started < 2000) {
    try { audit = JSON.parse(await readFile(join(dir, 'descendant.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; await new Promise(resolve => setTimeout(resolve, 20)); }
  }
  assert.ok(audit, 'wrapper never created the descendant');
  const terminationStarted = reason === 'timeout' ? started : performance.now();
  if (reason === 'aborted') controller.abort();
  await assert.rejects(pending, { code: reason });
  assert.ok(performance.now() - terminationStarted < (reason === 'timeout' ? 2300 : 850), 'termination waited for descendant-held pipes');
  await assert.rejects(access(audit.input), { code: 'ENOENT' });
  await new Promise(resolve => setTimeout(resolve, 50));
  assert.throws(() => process.kill(audit.pid, 0), { code: 'ESRCH' });
});
test('owns input bytes across asynchronous writes and supports explicit OCR opt-in', async (t) => {
  const { binaryPath } = await fakeParser(t, `import {readFileSync} from 'node:fs';
    const input=process.argv[process.argv.indexOf('--input')+1];
    if(process.argv.includes('--no-ocr') || readFileSync(input).toString()!==${JSON.stringify(bytes.toString())}) process.exit(2);
    process.stdout.write(${JSON.stringify(serialize(fixture()))});`);
  const reusable = Uint8Array.from(bytes);
  const pending = extractPdfDocument(reusable, { binaryPath, enableOcr: true });
  reusable.fill(0);
  assert.equal((await pending).inputSha256, inputSha256);
});
for (const [name, body, options, code] of [
  ['timeout', 'setInterval(()=>{},1000);', { timeoutMs: 100 }, 'timeout'],
  ['output cap', 'process.stdout.write("x".repeat(10000));', { maxOutputBytes: 100 }, 'output_limit'],
  ['signal crash', 'process.kill(process.pid,"SIGKILL");', {}, 'crashed'],
  ['document failure', 'process.exit(2);', {}, 'document'],
  ['malformed output', 'process.stdout.write("{bad");', {}, 'protocol'],
  ['invalid UTF-8', 'process.stdout.write(Buffer.from([255]));', {}, 'protocol'],
]) test(`subprocess classifies ${name}`, async (t) => {
  const { binaryPath } = await fakeParser(t, body);
  await assert.rejects(extractPdfDocument(bytes, { binaryPath, ...options }), { code });
});
test('unavailable binary, limits and cancellation remain distinct', async (t) => {
  const { binaryPath } = await fakeParser(t, 'setInterval(()=>{},1000);');
  await assert.rejects(extractPdfDocument(bytes, { binaryPath: `${binaryPath}-missing` }), { code: 'unavailable' });
  await assert.rejects(extractPdfDocument(bytes, { binaryPath, maxOutputBytes: 0 }), RangeError);
  await assert.rejects(extractPdfDocument(bytes, {}), TypeError);
  await assert.rejects(extractPdfDocument(bytes, { binaryPath, signal: AbortSignal.abort() }), { code: 'aborted' });
  const controller = new AbortController();
  const pending = extractPdfDocument(bytes, { binaryPath, signal: controller.signal });
  setTimeout(() => controller.abort(), 30);
  await assert.rejects(pending, { code: 'aborted' });
});
test('cleanup failure is reported, preserving an earlier extraction failure', async (t) => {
  const success = await fakeParser(t, `process.stdout.write(${JSON.stringify(serialize(fixture()))});`);
  const malformed = await fakeParser(t, 'process.stdout.write("bad");');
  const originalRm = fs.promises.rm;
  const scratch = [];
  fs.promises.rm = async (path, options) => {
    if (String(path).includes('pdf-parser-extract-')) {
      scratch.push(path);
      throw Object.assign(new Error('Injected cleanup failure'), { code: 'EACCES' });
    }
    return originalRm(path, options);
  };
  syncBuiltinESMExports();
  try {
    await assert.rejects(extractPdfDocument(bytes, { binaryPath: success.binaryPath }), { code: 'cleanup' });
    await assert.rejects(extractPdfDocument(bytes, { binaryPath: malformed.binaryPath }), (error) => error.code === 'protocol' && error.cleanupError.code === 'cleanup');
  } finally {
    fs.promises.rm = originalRm;
    syncBuiltinESMExports();
    await Promise.all(scratch.map((path) => originalRm(path, { recursive: true, force: true })));
  }
});
