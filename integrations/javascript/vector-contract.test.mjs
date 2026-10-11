import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArtifactJsonl, locateSourceRange } from './extract.mjs';
import { extractPdfPages } from './stream.mjs';

const input = Buffer.from('%PDF-vector-contract');
const sha = value => createHash('sha256').update(value).digest('hex');
const inputSha256 = sha(input);
const bbox = { x0: 10, y0: 20, x1: 70, y1: 40 };
const serialize = records => records.map(record => JSON.stringify(record)).join('\n') + '\n';
const parse = records => parseArtifactJsonl(serialize(records), { inputSha256 });
const countKeys = ['spans', 'blocks', 'rag_chunks', 'tables', 'form_fields', 'route_traces', 'specialist_requests', 'specialist_attempts', 'specialist_responses', 'specialist_results', 'debug_assets'];
function fixture(version = '0.19.0') {
  const common = (type, id, refs = {}) => ({ schema_name: type, schema_version: version, record_type: type,
    document_id: 'doc', source_id: inputSha256, provenance: { document_id: 'doc', source_id: inputSha256,
      input_sha256: inputSha256, artifact_id: id, span_ids: [], block_ids: [], chunk_ids: [], ...refs } });
  const text = 'Native 😀 evidence';
  const refs = { span_ids: ['span-0'], block_ids: ['block-0'] };
  const view = (id, kind) => ({ text_view_id: `${id}:text`, kind, offset_unit: 'utf8_byte', range_convention: 'half_open', normalization: 'none', text_sha256: sha(text) });
  const coverage = { status: 'recovery_required', completeness: 'unverified', native_span_count: 1, recognized_span_count: 0,
    requested_recovery: true, recovery_state: 'not_invoked', unresolved_region_count: 1,
    non_painting_span_count: 0, clipped_out_span_count: 0, uncertain_paint_span_count: 0 };
  const artifact_counts = Object.fromEntries(countKeys.map(key => [key, 0]));
  Object.assign(artifact_counts, { spans: 1, blocks: 1, rag_chunks: 1, route_traces: 2, specialist_requests: 1 });
  return [
    { ...common('document_manifest', 'document_manifest'), input_sha256: inputSha256, page_count: 1, artifact_counts,
      text_contract: { offset_unit: 'utf8_byte', range_convention: 'half_open', page_index_base: 0,
        geometry: { coordinate_space: 'pdf_user_space', unit: 'point', highlight_precision: 'span_bbox', display_transform: null } } },
    { ...common('span', 'span-0', refs), span_id: 'span-0', reconciled_block_id: 'block-0', page_index: 0, bbox, text,
      text_view: view('span-0', 'reconciled_span'), paint: { rendering_mode: 0, paint_state: 'painting', clip_state: 'unclipped', clip_bbox: null },
      content_scope: { page_index: 0, stream_object_num: null, stream_generation: 0, invocation_index: 0 } },
    { ...common('block', 'block-0', refs), block_id: 'block-0', page_index: 0, bbox, text, text_view: view('block-0', 'reconciled_block'),
      source_map: [{ text_start_byte: 0, text_end_byte: Buffer.byteLength(text), source_span_id: 'span-0', source_start_byte: 0, source_end_byte: Buffer.byteLength(text) }] },
    { ...common('rag_chunk', 'chunk-0', { ...refs, chunk_ids: ['chunk-0'] }), chunk_id: 'chunk-0', page_start: 0, page_end: 0, content: text,
      source_span_ids: ['span-0'], source_block_ids: ['block-0'], text_view: view('chunk-0', 'rag_chunk'),
      source_map: [{ text_start_byte: 0, text_end_byte: Buffer.byteLength(text), source_block_id: 'block-0', source_start_byte: 0, source_end_byte: Buffer.byteLength(text) }] },
    { ...common('route_trace', 'route-page-0', { route_reasons: ['unexplained_vector'] }), trace_kind: 'page_route', page_index: 0, region_index: null,
      reasons: ['unexplained_vector'], page_geometry: null, coverage: { ...coverage }, vector_evidence: {
        status: 'complete', shape_count: 6, unknown_count: 0, ignored_rule_count: 1, clipped_out_count: 0, native_accounted_count: 1,
        simple_graphic_count: 0, ambiguous_shape_count: 1, candidate_region_count: 1,
        max_shapes: 512, max_segments_per_path: 512, max_operators: 100000, max_candidate_regions: 64,
        operator_count: 40, content_bytes: 600, max_content_bytes: 8388608, max_graphics_depth: 32, max_form_invocations: 256 } },
    { ...common('route_trace', 'route-region-0', { route_reasons: ['unexplained_vector'] }), trace_kind: 'region_route', page_index: 0, region_index: 0,
      bbox, route: 'queue_ocr', reasons: ['unexplained_vector'], coverage: { ...coverage, native_span_count: 0 },
      specialist_status: 'requested', specialist_request_ids: ['ocr-request-0'],
      vector_evidence: { bbox: { ...bbox }, shape_count: 3, segment_count: 12, subpath_count: 3, native_coverage: 0, decision: 'unexplained_vector' } },
    { ...common('specialist_request', 'ocr-request-0'), request_id: 'ocr-request-0', page_index: 0, region_index: 0, requested_kind: 'ocr', crop_geometry: null },
  ];
}

test('0.19 preserves vector metadata and exact native source text and locators', () => {
  const records = fixture();
  const document = parse(records);
  assert.deepEqual(document.records[4].vector_evidence, records[4].vector_evidence);
  assert.deepEqual(document.records[5].vector_evidence, records[5].vector_evidence);
  assert.equal(document.sourceText, records[1].text);
  assert.equal(document.chunks[0].content, records[1].text);
  const located = locateSourceRange(document, 0, document.sourceText.length, { sourceTextSha256: document.sourceTextSha256 });
  assert.equal(located.segments[0].sourceSpanId, 'span-0');
  assert.deepEqual(located.segments[0].bbox, bbox);
  assert.equal(document.pageCoverage, 'unverified');
});

test('0.19 accepts unknown, partial and limited evidence without inventing candidates', () => {
  for (const status of ['complete', 'partial', 'limited']) {
    const records = fixture();
    records[4].vector_evidence.status = status;
    records[4].vector_evidence.unknown_count = status === 'complete' ? 0 : 1000;
    assert.ok(parse(records));
  }
  const records = fixture();
  records[4].vector_evidence = records[5].vector_evidence = null;
  assert.equal(parse(records).records[4].vector_evidence, null);
});

test('0.19 accepts a retained subset of a page candidate collection', () => {
  const records = fixture();
  records[4].vector_evidence.candidate_region_count = 2;
  records[4].vector_evidence.shape_count = 9;
  assert.ok(parse(records));
});

test('0.19 accepts reached resource caps without exceeding them', () => {
  const records = fixture();
  Object.assign(records[4].vector_evidence, { status: 'limited', operator_count: 100000, content_bytes: 8388608 });
  assert.ok(parse(records));
  Object.assign(records[4].vector_evidence, { operator_count: 0, content_bytes: 0 });
  assert.ok(parse(records));
});

test('0.19 retains a smaller vector extent inside a reused image OCR route', () => {
  const records = fixture();
  records[5].bbox = { x0: 0, y0: 0, x1: 100, y1: 100 };
  const document = parse(records);
  assert.deepEqual(document.records[5].vector_evidence.bbox, bbox);
  assert.deepEqual(document.records[5].bbox, records[5].bbox);
});

test('0.19 tolerates two-decimal route rounding and large nonzero origins', () => {
  for (const origin of [0, -10000, 1000000]) {
    const records = fixture();
    records[5].bbox = { x0: origin + 10, y0: origin + 20, x1: origin + 70, y1: origin + 40 };
    records[5].vector_evidence.bbox = { x0: origin + 9.995, y0: origin + 19.995, x1: origin + 70.005, y1: origin + 40.005 };
    assert.ok(parse(records));
  }
});

test('0.19 accepts a page summary when another OCR route covers its candidates', () => {
  const records = fixture();
  records[5].vector_evidence = null;
  records[5].region_index = null;
  records[6].region_index = null;
  assert.ok(parse(records));
});

test('0.19 accepts an empty known summary and requires no evidence on other stages', () => {
  const records = fixture();
  for (const key of ['shape_count', 'candidate_region_count', 'ignored_rule_count', 'native_accounted_count', 'ambiguous_shape_count']) records[4].vector_evidence[key] = 0;
  records[5].vector_evidence = null;
  const stage = { ...records[5], trace_kind: 'layout', provenance: { ...records[5].provenance, artifact_id: 'route-stage-0' } };
  delete stage.vector_evidence;
  records.push(stage);
  records[0].artifact_counts.route_traces++;
  assert.ok(parse(records));
});

for (const minor of [14, 15, 16, 17, 18]) test(`reader retains 0.${minor} compatibility without vector fields`, () => {
  const records = fixture(`0.${minor}.0`);
  delete records[4].vector_evidence;
  delete records[5].vector_evidence;
  assert.equal(parse(records).sourceText, records[1].text);
});

for (const [name, mutate] of [
  ['missing page evidence', r => { delete r[4].vector_evidence; }],
  ['missing region evidence', r => { delete r[5].vector_evidence; }],
  ['unknown status', r => { r[4].vector_evidence.status = 'visible'; }],
  ['negative count', r => { r[4].vector_evidence.unknown_count = -1; }],
  ['fractional count', r => { r[4].vector_evidence.shape_count = 3.5; }],
  ['unsafe count', r => { r[4].vector_evidence.unknown_count = 2 ** 53; }],
  ['missing summary count', r => { delete r[4].vector_evidence.simple_graphic_count; }],
  ['changed shape cap', r => { r[4].vector_evidence.max_shapes = 1024; }],
  ['changed segment cap', r => { r[4].vector_evidence.max_segments_per_path = 1024; }],
  ['changed operator cap', r => { r[4].vector_evidence.max_operators = 100001; }],
  ['changed region cap', r => { r[4].vector_evidence.max_candidate_regions = 65; }],
  ['missing operator count', r => { delete r[4].vector_evidence.operator_count; }],
  ['negative operator count', r => { r[4].vector_evidence.operator_count = -1; }],
  ['fractional operator count', r => { r[4].vector_evidence.operator_count = 0.5; }],
  ['operator budget overflow', r => { r[4].vector_evidence.operator_count = 100001; }],
  ['missing content byte count', r => { delete r[4].vector_evidence.content_bytes; }],
  ['negative content byte count', r => { r[4].vector_evidence.content_bytes = -1; }],
  ['fractional content byte count', r => { r[4].vector_evidence.content_bytes = 0.5; }],
  ['content byte budget overflow', r => { r[4].vector_evidence.content_bytes = 8388609; }],
  ['missing content byte cap', r => { delete r[4].vector_evidence.max_content_bytes; }],
  ['changed content byte cap', r => { r[4].vector_evidence.max_content_bytes = 8388609; }],
  ['missing graphics depth cap', r => { delete r[4].vector_evidence.max_graphics_depth; }],
  ['changed graphics depth cap', r => { r[4].vector_evidence.max_graphics_depth = 33; }],
  ['missing Form invocation cap', r => { delete r[4].vector_evidence.max_form_invocations; }],
  ['changed Form invocation cap', r => { r[4].vector_evidence.max_form_invocations = 257; }],
  ['shape cap overflow', r => { r[4].vector_evidence.shape_count = 513; }],
  ['region cap overflow', r => { r[4].vector_evidence.candidate_region_count = 65; }],
  ['classified count overflow', r => { r[4].vector_evidence.ambiguous_shape_count = 6; }],
  ['region count exceeds shapes', r => { r[4].vector_evidence.candidate_region_count = 7; }],
  ['missing page candidate reason', r => { r[4].reasons = []; }],
  ['missing page provenance reason', r => { r[4].provenance.route_reasons = []; }],
  ['null parent summary for known region', r => { r[4].vector_evidence = null; }],
  ['missing parent route', r => { r.splice(4, 1); r[0].artifact_counts.route_traces--; }],
  ['empty candidate shapes', r => { r[5].vector_evidence.shape_count = 0; }],
  ['missing candidate bbox', r => { delete r[5].bbox; }],
  ['empty candidate bbox', r => { r[5].bbox = { ...bbox, x1: bbox.x0 }; }],
  ['missing exact vector bbox', r => { delete r[5].vector_evidence.bbox; }],
  ['null exact vector bbox', r => { r[5].vector_evidence.bbox = null; }],
  ['empty exact vector bbox', r => { r[5].vector_evidence.bbox.x1 = bbox.x0; }],
  ['inverted exact vector bbox', r => { r[5].vector_evidence.bbox.y1 = bbox.y0 - 1; }],
  ['nonfinite exact vector bbox', r => { r[5].vector_evidence.bbox.x0 = Infinity; }],
  ['vector bbox beyond left route edge', r => { r[5].vector_evidence.bbox.x0 = bbox.x0 - 0.006; }],
  ['vector bbox beyond right route edge', r => { r[5].vector_evidence.bbox.x1 = bbox.x1 + 0.006; }],
  ['vector bbox beyond bottom route edge', r => { r[5].vector_evidence.bbox.y0 = bbox.y0 - 0.006; }],
  ['vector bbox beyond top route edge', r => { r[5].vector_evidence.bbox.y1 = bbox.y1 + 0.006; }],
  ['missing candidate count', r => { delete r[5].vector_evidence.segment_count; }],
  ['fractional candidate count', r => { r[5].vector_evidence.segment_count = 12.5; }],
  ['segment cap overflow', r => { r[5].vector_evidence.segment_count = 1537; }],
  ['subpaths exceed segments', r => { r[5].vector_evidence.subpath_count = 13; }],
  ['candidate shapes exceed remaining page shapes', r => { r[5].vector_evidence.shape_count = 4; }],
  ['negative coverage', r => { r[5].vector_evidence.native_coverage = -0.1; }],
  ['excessive coverage', r => { r[5].vector_evidence.native_coverage = 1.1; }],
  ['nonfinite coverage', r => { r[5].vector_evidence.native_coverage = Infinity; }],
  ['unknown decision', r => { r[5].vector_evidence.decision = 'recognized_text'; }],
  ['missing regional reason', r => { r[5].reasons = []; }],
  ['missing regional provenance reason', r => { r[5].provenance.route_reasons = []; }],
  ['native-only candidate', r => { r[5].route = 'native'; }],
  ['candidate without request status', r => { r[5].specialist_status = 'none'; }],
  ['unlinked candidate request', r => { r[5].specialist_request_ids = []; }],
  ['request wrong region', r => { r[6].region_index = 1; }],
  ['request wrong specialist', r => { r[6].requested_kind = 'table'; }],
  ['zero candidate summary', r => { r[4].vector_evidence.candidate_region_count = 0; }],
  ['missing inherited page geometry', r => { delete r[4].page_geometry; }],
  ['missing inherited request geometry', r => { delete r[6].crop_geometry; }],
  ['missing inherited paint', r => { delete r[1].paint; }],
  ['missing inherited scope', r => { delete r[1].content_scope; }],
  ['malformed inherited paint', r => { r[1].paint.rendering_mode = 3; }],
  ['malformed inherited scope', r => { r[1].content_scope.invocation_index = 1; }],
  ['missing inherited coverage count', r => { delete r[4].coverage.uncertain_paint_span_count; }],
]) test(`0.19 rejects ${name}`, () => {
  const records = fixture();
  mutate(records);
  assert.throws(() => parse(records), { code: 'protocol' });
});

test('0.19 rejects duplicate candidate region identities even with unique route IDs', () => {
  const records = fixture();
  const duplicate = structuredClone(records[5]);
  duplicate.provenance.artifact_id = 'route-region-1';
  records.push(duplicate);
  records[0].artifact_counts.route_traces++;
  records[4].vector_evidence.candidate_region_count = 2;
  records[4].vector_evidence.shape_count = 9;
  assert.throws(() => parse(records), { code: 'protocol' });
});

async function streamFixture(t, records) {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-vector-contract-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const counts = records[0].artifact_counts;
  const route_counts = { native_pages: 0, page_routes: 1, region_routes: 1, ocr_regions: 2, table_regions: 0, formula_regions: 0 };
  const lifecycle = (type, id, fields) => ({ ...records[0], schema_name: type, record_type: type,
    provenance: { ...records[0].provenance, artifact_id: id }, ...fields });
  const events = [{ ...records[0], streaming: true, errors: [] },
    lifecycle('page_started', 'page-started-0', { page_index: 0, status: 'running' }), ...records.slice(1),
    lifecycle('page_finished', 'page-finished-0', { page_index: 0, status: 'completed', artifact_counts: counts, route_counts }),
    lifecycle('document_finished', 'document_finished', { status: 'completed', errors: [], artifact_counts: counts, route_counts })];
  events.forEach((record, index) => Object.assign(record, { event_index: index, event_type: record.record_type,
    sequence_scope: record.record_type.startsWith('document_') ? 'document' : 'page' }));
  const binaryPath = join(directory, 'parser');
  await writeFile(binaryPath, `#!${process.execPath}\nprocess.stdout.write(${JSON.stringify(serialize(events))});\n`, { mode: 0o700 });
  return binaryPath;
}

test('0.19 streaming validates vector evidence before delivering a page', async t => {
  const records = fixture();
  const pages = [];
  const receipt = await extractPdfPages(input, { binaryPath: await streamFixture(t, records), onPage: page => pages.push(page) });
  assert.equal(receipt.schemaVersion, '0.19.0');
  assert.equal(receipt.complete, true);
  assert.deepEqual(pages[0].records.find(record => record.trace_kind === 'region_route').vector_evidence, records[5].vector_evidence);
  assert.equal(pages[0].sourceText, records[1].text);
});

test('0.19 streaming refuses a malformed vector page before callback', async t => {
  const records = fixture();
  records[5].vector_evidence.native_coverage = 2;
  const pages = [];
  await assert.rejects(extractPdfPages(input, { binaryPath: await streamFixture(t, records), onPage: page => pages.push(page) }), { code: 'protocol' });
  assert.equal(pages.length, 0);
});
