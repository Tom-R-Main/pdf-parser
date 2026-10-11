import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { terminateSubprocess } from './subprocess.mjs';
import { ocrArguments } from './ocr-options.mjs';
import { validatePageGeometry, validateRasterTransform, validateRasterPageContext } from './coordinates.mjs';

export class PdfExtractionError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'PdfExtractionError';
    this.code = code;
  }
}

const fail = (message) => { throw new PdfExtractionError('protocol', message); };
const hash = (value) => createHash('sha256').update(value).digest('hex');
const integer = (value) => Number.isSafeInteger(value) && value >= 0;
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/** Converts UTF-8 byte boundaries to JS UTF-16 positions without rounding. */
export function utf8BoundaryMap(text) {
  if (typeof text !== 'string' || !text.isWellFormed()) fail('Text is not well-formed Unicode');
  const positions = new Map([[0, 0]]);
  let byte = 0;
  let unit = 0;
  for (const character of text) {
    byte += Buffer.byteLength(character);
    unit += character.length;
    positions.set(byte, unit);
  }
  return positions;
}

function range(mapping, start, end, label) {
  if (!integer(start) || !integer(end) || end < start || !mapping.has(start) || !mapping.has(end)) {
    fail(`Invalid UTF-8 range for ${label}`);
  }
  return [mapping.get(start), mapping.get(end)];
}

const textOf = (record) => record.record_type === 'rag_chunk' ? record.content : record.text;
const idOf = (record) => record.span_id ?? record.block_id ?? record.chunk_id;

function checkTextView(record, expectedKind) {
  const text = textOf(record);
  const boundaries = utf8BoundaryMap(text);
  const view = record.text_view;
  if (!object(view) || view.text_view_id !== `${idOf(record)}:text` || view.kind !== expectedKind ||
      view.offset_unit !== 'utf8_byte' || view.range_convention !== 'half_open' ||
      view.normalization !== 'none' || view.text_sha256 !== hash(text)) fail('Invalid text_view identity or hash');
  return boundaries;
}

function checkSourceMap(record, sources, sourceField, boundaries) {
  const text = textOf(record);
  if (!Array.isArray(record.source_map)) fail('Missing source_map');
  let cursor = 0;
  const referenced = new Set();
  for (const segment of record.source_map) {
    if (!object(segment) || segment.text_start_byte !== cursor || segment.text_end_byte <= cursor) fail('Source map is not ordered full coverage');
    const [start, end] = range(boundaries, segment.text_start_byte, segment.text_end_byte, idOf(record));
    const sourceId = segment[sourceField];
    if (sourceId === null) {
      if (segment.source_start_byte !== null || segment.source_end_byte !== null) fail('Synthetic map has source offsets');
      if (!/^\s*$/u.test(text.slice(start, end))) fail('Synthetic map contains non-separator text');
    } else {
      const source = sources.get(sourceId);
      if (!source) fail(`Unresolved ${sourceField}`);
      if (record.record_type === 'block' && source.record.page_index !== record.page_index) fail('Block source span page mismatch');
      if (record.record_type === 'rag_chunk' && (source.record.page_index < record.page_start || source.record.page_index > record.page_end)) fail('Chunk source block page mismatch');
      const [sourceStart, sourceEnd] = range(source.boundaries, segment.source_start_byte, segment.source_end_byte, sourceId);
      if (text.slice(start, end) !== textOf(source.record).slice(sourceStart, sourceEnd)) fail('Source map slice mismatch');
      referenced.add(sourceId);
    }
    cursor = segment.text_end_byte;
  }
  if (cursor !== Buffer.byteLength(text)) fail('Source map does not cover text');
  return referenced;
}

function checkIdentitySet(ids, expected, label) {
  if (!Array.isArray(ids) || ids.length !== expected.size || new Set(ids).size !== ids.length || ids.some((id) => !expected.has(id))) fail(`Inconsistent ${label}`);
}

/** Validates batch JSONL before projecting any host-facing source positions. */
export function parseArtifactJsonl(rawJsonl, { inputSha256, expectedSourceId } = {}) {
  if (typeof rawJsonl !== 'string' || !/^[a-f0-9]{64}$/.test(inputSha256 ?? '')) fail('An input SHA-256 is required');
  const lines = rawJsonl.split('\n');
  if (lines.at(-1) === '') lines.pop();
  const records = lines.map((line) => {
    try { return JSON.parse(line); } catch { fail('Malformed artifact JSONL'); }
  });
  const manifest = records[0];
  if (!object(manifest) || manifest.record_type !== 'document_manifest') fail('Expected manifest first');
  if (!/^0\.(14|15|16|17|18|19)\.\d+$/.test(manifest.schema_version ?? '') || manifest.schema_name !== 'document_manifest' ||
      typeof manifest.document_id !== 'string' || !manifest.document_id || !integer(manifest.page_count) ||
      manifest.input_sha256 !== inputSha256) fail('Unsupported schema or manifest input identity');
  if (!(manifest.source_id === null || (typeof manifest.source_id === 'string' && manifest.source_id.length > 0)) ||
      (expectedSourceId !== undefined && manifest.source_id !== expectedSourceId)) fail('Invalid or mismatched source identity');
  const contract = manifest.text_contract;
  if (!object(contract) || contract.offset_unit !== 'utf8_byte' || contract.range_convention !== 'half_open' ||
      contract.page_index_base !== 0 || contract.geometry?.coordinate_space !== 'pdf_user_space' ||
      contract.geometry.unit !== 'point' || contract.geometry.highlight_precision !== 'span_bbox' ||
      contract.geometry.display_transform !== null) fail('Unsupported manifest text contract');
  const artifactIds = new Set();
  const specialistIdFields = { specialist_request: 'request_id', specialist_attempt: 'attempt_id',
    specialist_response: 'response_id', specialist_result: 'specialist_result_id' };
  for (const record of records) {
    const provenance = record?.provenance;
    // Specialist compatibility provenance ids identify a class, not a record.
    // Their document-global record-owned ids are the unique identity instead.
    const idField = specialistIdFields[record?.record_type];
    const identity = idField ? record[idField] : provenance?.artifact_id;
    // 0.14 chunks carried a default internal label when the caller supplied no
    // source identity. Only provenance binds those legacy chunks to the source.
    const legacyChunkSource = manifest.schema_version.startsWith('0.14.') && manifest.source_id === null &&
      record?.record_type === 'rag_chunk' && typeof record.source_id === 'string' && record.source_id.length > 0;
    if (!object(record) || typeof record.record_type !== 'string' || record.schema_name !== record.record_type || record.schema_version !== manifest.schema_version ||
        record.document_id !== manifest.document_id || (!legacyChunkSource && record.source_id !== manifest.source_id) ||
        !object(provenance) || provenance.document_id !== manifest.document_id ||
        provenance.source_id !== manifest.source_id || provenance.input_sha256 !== inputSha256 ||
        typeof provenance.artifact_id !== 'string' || !provenance.artifact_id ||
        typeof identity !== 'string' || !identity || artifactIds.has(identity)) {
      fail('Inconsistent record provenance or duplicate artifact id');
    }
    artifactIds.add(identity);
  }
  if (records.slice(1).some((record) => record.record_type === 'document_manifest')) fail('Duplicate manifest');
  const spans = records.filter((record) => record.record_type === 'span');
  const blocks = records.filter((record) => record.record_type === 'block');
  const chunks = records.filter((record) => record.record_type === 'rag_chunk');
  const index = (items, kind, prefix) => new Map(items.map((record) => {
    const id = idOf(record);
    if (typeof id !== 'string' || !new RegExp(`^${prefix}-\\d+$`).test(id) || record.provenance.artifact_id !== id) fail('Invalid artifact identity');
    if (kind !== 'rag_chunk' && (!integer(record.page_index) || record.page_index >= manifest.page_count)) fail('Invalid page index');
    if (kind !== 'rag_chunk') {
      const box = record.bbox;
      if (!object(box) || !['x0', 'y0', 'x1', 'y1'].every((key) => Number.isFinite(box[key])) ||
          box.x0 > box.x1 || box.y0 > box.y1) fail('Invalid PDF-space bbox');
    }
    return [id, { record, boundaries: checkTextView(record, kind) }];
  }));
  const spanIndex = index(spans, 'reconciled_span', 'span');
  const blockIndex = index(blocks, 'reconciled_block', 'block');
  const chunkIndex = index(chunks, 'rag_chunk', 'chunk');
  const unresolvedProvenanceLinks = [];
  for (const [field, items] of [['spans', spans], ['blocks', blocks], ['rag_chunks', chunks]]) {
    if (manifest.artifact_counts?.[field] !== items.length) fail(`Manifest ${field} count mismatch`);
  }
  for (const [field, type] of [['tables', 'table'], ['form_fields', 'form_field'], ['route_traces', 'route_trace'],
    ['specialist_requests', 'specialist_request'], ['specialist_attempts', 'specialist_attempt'],
    ['specialist_responses', 'specialist_response'], ['specialist_results', 'specialist_result'], ['debug_assets', 'debug_asset']]) {
    if (field in manifest.artifact_counts && manifest.artifact_counts[field] !== records.filter((record) => record.record_type === type).length) fail(`Manifest ${field} count mismatch`);
  }
  for (const record of records) {
    for (const [field, sourceIndex] of [['span_ids', spanIndex], ['block_ids', blockIndex], ['chunk_ids', chunkIndex]]) {
      const ids = record.provenance[field];
      if (ids === undefined) continue;
      if (!Array.isArray(ids) || ids.some((id) => typeof id !== 'string')) fail(`Invalid provenance ${field}`);
      for (const id of ids) {
        if (sourceIndex.has(id)) continue;
        // Legacy table block refs precede reconciliation and can name blocks
        // absent from public artifacts. Retain and diagnose, never use in maps.
        if (record.record_type === 'table' && field === 'block_ids') {
          unresolvedProvenanceLinks.push({ recordType: record.record_type, artifactId: record.provenance.artifact_id, field, id });
        } else fail(`Unresolved provenance ${field}`);
      }
    }
  }
  for (const block of blocks) {
    const ids = checkSourceMap(block, spanIndex, 'source_span_id', blockIndex.get(block.block_id).boundaries);
    checkIdentitySet(block.provenance.span_ids, ids, 'block span provenance');
    checkIdentitySet(block.provenance.block_ids, new Set([block.block_id]), 'block identity provenance');
  }
  for (const chunk of chunks) {
    if (!integer(chunk.page_start) || !integer(chunk.page_end) || chunk.page_end < chunk.page_start || chunk.page_end >= manifest.page_count) fail('Invalid chunk pages');
    const blockIds = checkSourceMap(chunk, blockIndex, 'source_block_id', chunkIndex.get(chunk.chunk_id).boundaries);
    const spanIds = new Set([...blockIds].flatMap((id) => blockIndex.get(id).record.provenance.span_ids));
    checkIdentitySet(chunk.source_block_ids, blockIds, 'chunk source_block_ids');
    checkIdentitySet(chunk.source_span_ids, spanIds, 'chunk source_span_ids');
    checkIdentitySet(chunk.provenance.block_ids, blockIds, 'chunk block provenance');
    checkIdentitySet(chunk.provenance.span_ids, spanIds, 'chunk span provenance');
    checkIdentitySet(chunk.provenance.chunk_ids, new Set([chunk.chunk_id]), 'chunk identity provenance');
  }
  const tables = records.filter(record => record.record_type === 'table');
  if (!manifest.schema_version.startsWith('0.14.')) {
    const owners = new Map();
    for (const block of blocks) for (const id of block.provenance.span_ids) {
      if (!owners.has(id)) owners.set(id, new Set());
      owners.get(id).add(block.block_id);
    }
    for (const span of spans) {
      const expected = owners.get(span.span_id) ?? new Set();
      if (expected.size > 1 || span.reconciled_block_id !== ([...expected][0] ?? null)) fail('Invalid reconciled span ownership');
      checkIdentitySet(span.provenance.block_ids, expected, 'span block provenance');
      checkIdentitySet(span.provenance.span_ids, new Set([span.span_id]), 'span identity provenance');
    }
    const validateLinks = record => {
      if (!object(record) || !Array.isArray(record.source_span_ids) || !integer(record.page_index) || record.page_index >= manifest.page_count) fail('Invalid table source evidence');
      const expected = new Set();
      for (const id of record.source_span_ids) {
        const span = spanIndex.get(id)?.record;
        if (!span || span.page_index !== record.page_index) fail('Unresolved or cross-page table span');
        for (const owner of owners.get(id) ?? []) expected.add(owner);
      }
      checkIdentitySet(record.reconciled_block_ids, expected, 'reconciled table block linkage');
    };
    for (const table of tables) {
      validateLinks(table);
      if (!Array.isArray(table.rows)) fail('Invalid table rows');
      for (const row of table.rows) {
        if (!object(row) || !Array.isArray(row.cells)) fail('Invalid table cells');
        for (const cell of row.cells) {
          validateLinks(cell);
          if (cell.page_index !== table.page_index) fail('Cell page does not match its table');
        }
      }
    }
  }
  const pageOutcomes = records.filter(record => record.record_type === 'route_trace' && record.trace_kind === 'page_route')
    .map(record => ({ pageIndex: record.page_index, ...record.coverage }));
  if (/^0\.(18|19)\./u.test(manifest.schema_version)) {
    const pageGeometry = new Map();
    const boxClose = (actual, expected, marginX = 0, marginY = 0) => object(expected) &&
      ['x0', 'y0', 'x1', 'y1'].every(key => Number.isFinite(expected[key]) &&
        Math.abs(actual[key] - expected[key]) <= (key[0] === 'x' ? marginX : marginY) + 0.0055 + 64 * Number.EPSILON * Math.max(1, Math.abs(expected[key])));
    const check = callback => { try { return callback(); } catch { fail('Invalid coordinate transform contract'); } };
    for (const record of records.filter(record => record.record_type === 'route_trace' && record.trace_kind === 'page_route')) {
      if (record.page_geometry === undefined) fail('Missing page geometry contract');
      if (record.page_geometry !== null) pageGeometry.set(record.page_index, check(() => validatePageGeometry(record.page_geometry)));
    }
    for (const record of records) {
      const geometry = pageGeometry.get(record.page_index);
      if (record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr') {
        const transform = record.raster_transform;
        const execution = record.execution;
        if (transform === undefined || !object(execution) || !integer(execution.pixel_width) || !integer(execution.pixel_height)) fail('Missing OCR raster transform contract');
        if (transform === null) {
          if (['completed', 'empty'].includes(record.attempt_status) || execution.pixel_width !== 0 || execution.pixel_height !== 0) fail('Missing accepted OCR raster transform');
          continue;
        }
        const mapped = check(() => validateRasterTransform(transform));
        if (transform.pixel_width !== execution.pixel_width || transform.pixel_height !== execution.pixel_height ||
            (record.crop !== null && (!object(record.crop) || transform.pixel_width !== record.crop.pixel_width || transform.pixel_height !== record.crop.pixel_height)) ||
            !boxClose(mapped, record.crop?.bbox ?? record.provenance.bbox)) fail('Inconsistent OCR raster evidence');
        if (geometry) check(() => validateRasterPageContext(transform, geometry, record.config?.dpi, { fullPage: record.region_index === null }));
      } else if (record.record_type === 'specialist_attempt' && record.specialist_kind === 'formula') {
        if (!object(record.config) || typeof record.config.crop_backed !== 'boolean') fail('Invalid formula crop config');
        const transform = record.config.crop_transform;
        if (transform === undefined) fail('Missing formula crop transform contract');
        if (transform === null) {
          if (record.config.crop_backed === true) fail('Missing accepted formula crop transform');
          continue;
        }
        const mapped = check(() => validateRasterTransform(transform));
        const box = record.config.crop_bbox;
        const matrix = transform.pixel_to_pdf;
        const marginX = Math.abs(matrix[0]) + Math.abs(matrix[2]);
        const marginY = Math.abs(matrix[1]) + Math.abs(matrix[3]);
        if (record.config.crop_backed !== true || transform.pixel_width !== record.config.crop_pixel_width || transform.pixel_height !== record.config.crop_pixel_height ||
            !boxClose(mapped, box, marginX, marginY) || mapped.x0 > box.x0 + 0.0055 || mapped.y0 > box.y0 + 0.0055 ||
            mapped.x1 < box.x1 - 0.0055 || mapped.y1 < box.y1 - 0.0055) fail('Inconsistent formula raster evidence');
        if (geometry) check(() => validateRasterPageContext(transform, geometry, record.config.crop_dpi));
      } else if (record.record_type === 'specialist_request') {
        if (record.crop_geometry === undefined) fail('Missing request crop geometry contract');
        if (record.crop_geometry !== null) check(() => validateRasterTransform(record.crop_geometry));
      }
    }
  }
  if (/^0\.(16|17|18|19)\./u.test(manifest.schema_version)) {
    const validBox = box => object(box) && ['x0', 'y0', 'x1', 'y1'].every(key => Number.isFinite(box[key])) && box.x0 <= box.x1 && box.y0 <= box.y1;
    for (const span of spans) {
      const paint = span.paint;
      if (!object(paint) || !(paint.rendering_mode === null || (integer(paint.rendering_mode) && paint.rendering_mode <= 7)) ||
          !['painting', 'non_painting', 'unknown'].includes(paint.paint_state) || !['unclipped', 'inside', 'outside', 'partial', 'unknown'].includes(paint.clip_state) ||
          !(paint.clip_bbox === null || validBox(paint.clip_bbox)) ||
          (paint.clip_state === 'unclipped' && paint.clip_bbox !== null) ||
          (['inside', 'outside', 'partial'].includes(paint.clip_state) && paint.clip_bbox === null) ||
          (paint.paint_state === 'painting' && (paint.rendering_mode === null || [3, 7].includes(paint.rendering_mode))) ||
          (paint.paint_state === 'non_painting' && ![3, 7].includes(paint.rendering_mode))) fail('Invalid paint evidence');
      if (/^0\.(17|18|19)\./u.test(manifest.schema_version)) {
        const scope = span.content_scope;
        if (!(scope === null || (object(scope) && scope.page_index === span.page_index &&
            integer(scope.stream_generation) && scope.stream_generation <= 65535 && integer(scope.invocation_index) && scope.invocation_index <= 0xffffffff &&
            (scope.stream_object_num === null ? scope.stream_generation === 0 && scope.invocation_index === 0 :
              integer(scope.stream_object_num) && scope.stream_object_num > 0 && scope.stream_object_num <= 0xffffffff && scope.invocation_index > 0)))) fail('Invalid content scope');
      }
    }
    const requests = new Map(records.filter(record => record.record_type === 'specialist_request').map(record => [record.request_id, record]));
    const attempts = new Map(records.filter(record => record.record_type === 'specialist_attempt').map(record => [record.attempt_id, record]));
    const attemptStatuses = ['not_invoked', 'completed', 'empty', 'unavailable', 'failed', 'timeout', 'invalid_output'];
    // Specialist context is a view of the same page's public artifacts.
    for (const record of records.filter(record => record.record_type.startsWith('specialist_'))) {
      for (const [field, items, sourceIndex, idField] of [['span_ids', 'spans', spanIndex, 'span_id'], ['block_ids', 'blocks', blockIndex, 'block_id']]) {
        if (record[field] !== undefined && (!Array.isArray(record[field]) || new Set(record[field]).size !== record[field].length ||
            record[field].some(id => !sourceIndex.has(id) || sourceIndex.get(id).record.page_index !== record.page_index))) fail('Invalid specialist artifact references');
        if (record[items] === undefined) continue;
        if (!Array.isArray(record[items])) fail('Invalid specialist context');
        const seen = new Set();
        for (const item of record[items]) {
          const original = object(item) ? sourceIndex.get(item[idField])?.record : undefined;
          if (!original || seen.has(item[idField]) || original.page_index !== record.page_index || item.text !== original.text ||
              // Public bboxes use two decimals; specialist context uses three.
              !validBox(item.bbox) || ['x0', 'y0', 'x1', 'y1'].some(key => Math.abs(item.bbox[key] - original.bbox[key]) > 0.0055 + Number.EPSILON * Math.max(1, Math.abs(original.bbox[key])))) fail('Invalid specialist context');
          if (items === 'spans' && (!object(item.paint) || ['rendering_mode', 'paint_state', 'clip_state'].some(key => item.paint[key] !== original.paint[key]) ||
              (original.paint.clip_bbox === null ? item.paint.clip_bbox !== null : !validBox(item.paint.clip_bbox) ||
                ['x0', 'y0', 'x1', 'y1'].some(key => item.paint.clip_bbox[key] !== original.paint.clip_bbox[key])))) fail('Inconsistent specialist paint evidence');
          if (items === 'spans' && /^0\.(17|18|19)\./u.test(manifest.schema_version) &&
              (original.content_scope === null ? item.content_scope !== null : !object(item.content_scope) ||
                ['page_index', 'stream_object_num', 'stream_generation', 'invocation_index'].some(key => item.content_scope[key] !== original.content_scope[key]))) fail('Inconsistent specialist content scope');
          seen.add(item[idField]);
        }
        if (record[field] !== undefined) checkIdentitySet(record[field], seen, 'specialist context identity');
      }
    }
    for (const record of records.filter(record => ['specialist_attempt', 'specialist_response', 'specialist_result'].includes(record.record_type) && record.specialist_kind === 'ocr')) {
      const request = requests.get(record.request_id);
      if (!integer(record.page_index) || record.page_index >= manifest.page_count ||
          !(record.region_index === null || integer(record.region_index)) || !request ||
          request.page_index !== record.page_index || request.region_index !== record.region_index || request.requested_kind !== 'ocr') fail('Invalid OCR request scope');
      if (record.selected_attempt_id !== undefined && record.selected_attempt_id !== null) {
        const selected = attempts.get(record.selected_attempt_id);
        if (!selected || selected.specialist_kind !== 'ocr' || selected.selected !== true || !['completed', 'empty'].includes(selected.attempt_status) ||
            selected.page_index !== record.page_index || selected.region_index !== record.region_index || selected.request_id !== record.request_id ||
            (record.record_type === 'specialist_result' && selected.attempt_status !== 'completed')) fail('Invalid selected OCR attempt');
      }
      if (record.record_type === 'specialist_result' && (record.status !== 'completed' || typeof record.selected_attempt_id !== 'string')) fail('Invalid completed OCR result');
      if (record.record_type === 'specialist_response') {
        const scoped = [...attempts.values()].filter(attempt => attempt.request_id === record.request_id && attempt.specialist_kind === 'ocr');
        // Responses describe the last attempt; an earlier completed winner may
        // still be selected after a later retry fails.
        const last = scoped.at(-1);
        const status = ['failed', 'timeout', 'invalid_output'].includes(last?.attempt_status) ? 'failed' : (last?.attempt_status ?? 'not_invoked');
        if (record.attempt_count !== scoped.length || record.status !== status) fail('Invalid OCR response summary');
      }
      if (record.record_type !== 'specialist_attempt') continue;
      if (typeof record.selected !== 'boolean' || !attemptStatuses.includes(record.attempt_status) ||
          (record.selected && !['completed', 'empty'].includes(record.attempt_status))) fail('Invalid OCR attempt status');
      if (!object(record.config) || !['max_image_pixels', 'max_image_bytes', 'max_regions_per_page', 'max_attempts_per_page'].every(key => integer(record.config[key]))) fail('Invalid OCR execution budgets');
      const crop = record.crop;
      if (crop === null && record.region_index === null) continue;
      if (!object(crop) || !validBox(crop.bbox) || !integer(crop.dpi) || crop.dpi < 1 || !integer(crop.pixel_width) || !integer(crop.pixel_height) ||
          !(crop.image_sha256 === null || (typeof crop.image_sha256 === 'string' && /^[a-f0-9]{64}$/u.test(crop.image_sha256))) || !(crop.image_byte_length === null || integer(crop.image_byte_length))) fail('Invalid OCR crop evidence');
      if (['completed', 'empty'].includes(record.attempt_status) && (crop.pixel_width < 1 || crop.pixel_height < 1 || crop.image_sha256 === null || crop.image_byte_length === null || crop.image_byte_length < 24 ||
          BigInt(crop.pixel_width) * BigInt(crop.pixel_height) > BigInt(record.config.max_image_pixels) || crop.image_byte_length > record.config.max_image_bytes)) fail('OCR crop exceeds its declared budgets');
    }
  }
  if (!manifest.schema_version.startsWith('0.14.')) {
    const statuses = new Set(['text_available', 'empty_unverified', 'recovery_required', 'recovery_failed', 'recovered']);
    const recoveryStates = new Set(['not_required', 'not_invoked', 'completed', 'empty', 'unavailable', 'failed', 'timeout', 'invalid_output']);
    const failedStates = new Set(['unavailable', 'failed', 'timeout', 'invalid_output']);
    const pageRoutes = new Set();
    for (const record of records.filter(record => record.record_type === 'route_trace' && ['page_route', 'region_route'].includes(record.trace_kind))) {
      const assessment = record.coverage;
      if (/^0\.(16|17|18|19)\./u.test(manifest.schema_version) && (!object(assessment) || !['non_painting_span_count', 'clipped_out_span_count', 'uncertain_paint_span_count'].every(key => integer(assessment[key])))) fail('Invalid paint coverage counts');
      if (!integer(record.page_index) || record.page_index >= manifest.page_count ||
          !object(assessment) || !statuses.has(assessment.status) || assessment.completeness !== 'unverified' ||
          !recoveryStates.has(assessment.recovery_state) || typeof assessment.requested_recovery !== 'boolean' ||
          !['native_span_count', 'recognized_span_count', 'unresolved_region_count'].every(key => integer(assessment[key]))) fail('Invalid coverage assessment');
      if (record.trace_kind === 'page_route') {
        if (pageRoutes.has(record.page_index)) fail('Duplicate page coverage assessment');
        pageRoutes.add(record.page_index);
      }
      if (!assessment.requested_recovery) {
        if (!['text_available', 'empty_unverified'].includes(assessment.status) || assessment.recovery_state !== 'not_required' || assessment.unresolved_region_count !== 0) fail('Inconsistent coverage assessment');
        if (assessment.status === 'empty_unverified' && (assessment.native_span_count || assessment.recognized_span_count)) fail('Empty coverage has retained text');
      } else if (assessment.recovery_state === 'not_required' || !['recovery_required', 'recovery_failed', 'recovered'].includes(assessment.status) ||
          (assessment.status === 'recovery_failed') !== failedStates.has(assessment.recovery_state) ||
          (assessment.status === 'recovered' && (assessment.recovery_state !== 'completed' || assessment.recognized_span_count === 0 || assessment.unresolved_region_count !== 0))) fail('Inconsistent recovery assessment');
    }
  }
  if (manifest.schema_version.startsWith('0.19.')) {
    const classified = ['ignored_rule_count', 'clipped_out_count', 'native_accounted_count', 'simple_graphic_count', 'ambiguous_shape_count'];
    const limits = { max_shapes: 512, max_segments_per_path: 512, max_operators: 100000, max_candidate_regions: 64,
      max_content_bytes: 8388608, max_graphics_depth: 32, max_form_invocations: 256 };
    const validBox = box => object(box) && ['x0', 'y0', 'x1', 'y1'].every(key => Number.isFinite(box[key])) && box.x0 < box.x1 && box.y0 < box.y1;
    const containedBox = (inner, outer) => validBox(inner) && validBox(outer) && ['x0', 'y0', 'x1', 'y1'].every(key => {
      // Route bboxes use two decimals; candidate evidence retains exact values.
      const tolerance = 0.0055 + 64 * Number.EPSILON * Math.max(1, Math.abs(inner[key]), Math.abs(outer[key]));
      return key.endsWith('0') ? inner[key] >= outer[key] - tolerance : inner[key] <= outer[key] + tolerance;
    });
    const pageEvidence = new Map();
    const requests = new Map(records.filter(record => record.record_type === 'specialist_request').map(record => [record.request_id, record]));
    const hasReason = record => Array.isArray(record.reasons) && record.reasons.includes('unexplained_vector') &&
      Array.isArray(record.provenance.route_reasons) && record.provenance.route_reasons.includes('unexplained_vector');
    const routeRecords = records.filter(record => record.record_type === 'route_trace' && ['page_route', 'region_route'].includes(record.trace_kind));
    for (const record of routeRecords) {
      if (record.vector_evidence === undefined) fail('Missing vector evidence');
      if (record.trace_kind !== 'page_route') continue;
      const value = record.vector_evidence;
      if (value !== null) {
        if (!object(value) || !['complete', 'partial', 'limited'].includes(value.status) ||
            !['shape_count', 'unknown_count', 'candidate_region_count', 'operator_count', 'content_bytes', ...classified].every(key => integer(value[key])) ||
            Object.entries(limits).some(([key, expected]) => value[key] !== expected) ||
            value.shape_count > value.max_shapes || value.candidate_region_count > value.max_candidate_regions ||
            value.operator_count > value.max_operators || value.content_bytes > value.max_content_bytes ||
            classified.reduce((sum, key) => sum + value[key], 0) > value.shape_count ||
            value.candidate_region_count > value.shape_count || (value.candidate_region_count > 0 && !hasReason(record))) fail('Invalid page vector evidence');
      }
      pageEvidence.set(record.page_index, { value, regions: new Set(), shapes: 0 });
    }
    for (const record of routeRecords.filter(record => record.trace_kind === 'region_route' && record.vector_evidence !== null)) {
      const value = record.vector_evidence;
      const page = pageEvidence.get(record.page_index);
      if (!object(value) || !page?.value || !integer(record.region_index) || page.regions.has(record.region_index) ||
          !['shape_count', 'segment_count', 'subpath_count'].every(key => integer(value[key]) && value[key] > 0) ||
          value.decision !== 'unexplained_vector' || !Number.isFinite(value.native_coverage) || value.native_coverage < 0 || value.native_coverage > 1 ||
          value.shape_count > page.value.shape_count || value.segment_count > value.shape_count * page.value.max_segments_per_path ||
          value.subpath_count > value.segment_count || !containedBox(value.bbox, record.bbox) ||
          record.route !== 'queue_ocr' || !hasReason(record) ||
          record.specialist_status !== 'requested' || !Array.isArray(record.specialist_request_ids) ||
          !record.specialist_request_ids.some(id => {
            const request = requests.get(id);
            return request?.requested_kind === 'ocr' && request.page_index === record.page_index && request.region_index === record.region_index;
          })) fail('Invalid region vector evidence');
      page.regions.add(record.region_index);
      page.shapes += value.shape_count;
      // A projection may retain only a subset of the page's candidate regions.
      if (page.regions.size > page.value.candidate_region_count ||
          page.shapes + classified.reduce((sum, key) => sum + page.value[key], 0) > page.value.shape_count) fail('Inconsistent vector candidate counts');
    }
  }
  const sourceMap = [];
  const texts = [];
  let position = 0;
  for (const block of blocks) {
    if (texts.length) {
      sourceMap.push({ start: position, end: position + 2, sourceBlockId: null, sourceSpanId: null, pageIndex: null, bbox: null, sourceStart: null, sourceEnd: null });
      position += 2;
    }
    const boundaries = blockIndex.get(block.block_id).boundaries;
    for (const segment of block.source_map) {
      const [start, end] = range(boundaries, segment.text_start_byte, segment.text_end_byte, block.block_id);
      const span = spanIndex.get(segment.source_span_id);
      const spanRange = span ? range(span.boundaries, segment.source_start_byte, segment.source_end_byte, segment.source_span_id) : [null, null];
      sourceMap.push({ start: position + start, end: position + end, sourceBlockId: block.block_id,
        sourceSpanId: segment.source_span_id, pageIndex: block.page_index,
        bbox: span?.record.bbox ?? null, sourceStart: spanRange[0], sourceEnd: spanRange[1] });
    }
    texts.push(block.text);
    position += block.text.length;
  }
  const sourceText = texts.join('\n\n');
  return { rawJsonl, records, manifest, inputSha256, spans, blocks, chunks, tables, pageOutcomes, sourceText,
    sourceTextSha256: hash(sourceText), sourceMap, unresolvedProvenanceLinks, offsetUnit: 'utf16_code_unit',
    rangeConvention: 'half_open', normalization: 'none', pageCoverage: 'unverified' };
}

/** Prompt projection does not modify the authoritative source text or locators. */
export function projectPromptText(document, maxUtf16Units) {
  if (!integer(maxUtf16Units)) throw new RangeError('maxUtf16Units must be a nonnegative safe integer');
  let end = Math.min(document.sourceText.length, maxUtf16Units);
  if (end > 0 && end < document.sourceText.length && /[\uD800-\uDBFF]/.test(document.sourceText[end - 1]) && /[\uDC00-\uDFFF]/.test(document.sourceText[end])) end--;
  return { text: document.sourceText.slice(0, end), truncated: end < document.sourceText.length, sourceTextSha256: document.sourceTextSha256, sourceStart: 0, sourceEnd: end, offsetUnit: 'utf16_code_unit' };
}

/** Joins half-open source-text positions to span geometry, including explicit gaps. */
export function locateSourceRange(document, startOffset, endOffset, { sourceTextSha256 } = {}) {
  if (sourceTextSha256 !== document.sourceTextSha256 || hash(document.sourceText) !== sourceTextSha256) fail('Source text hash mismatch');
  const boundary = offset => offset <= document.sourceText.length && !(offset > 0 && offset < document.sourceText.length &&
    /[\uD800-\uDBFF]/.test(document.sourceText[offset - 1]) && /[\uDC00-\uDFFF]/.test(document.sourceText[offset]));
  if (!integer(startOffset) || !integer(endOffset) || endOffset < startOffset ||
      !boundary(startOffset) || !boundary(endOffset)) fail('Invalid UTF-16 source range');
  const segments = [];
  for (const segment of document.sourceMap) {
    const start = Math.max(startOffset, segment.start);
    const end = Math.min(endOffset, segment.end);
    if (end <= start) continue;
    segments.push({ ...segment, start, end,
      sourceStart: segment.sourceStart === null ? null : segment.sourceStart + start - segment.start,
      sourceEnd: segment.sourceStart === null ? null : segment.sourceStart + end - segment.start });
  }
  return { startOffset, endOffset, sourceTextSha256, offsetUnit: 'utf16_code_unit', rangeConvention: 'half_open', segments };
}

function runParser(binaryPath, args, { timeoutMs, maxOutputBytes, signal }) {
  return new Promise((resolve, reject) => {
    let child;
    // A private POSIX process group includes wrapper/OCR descendants. Killing
    // only the wrapper can leave workers alive and their output pipes open.
    const grouped = process.platform !== 'win32';
    try { child = spawn(binaryPath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, detached: grouped }); }
    catch (cause) { reject(new PdfExtractionError('unavailable', 'Parser could not be started', { cause })); return; }
    const output = [];
    let bytes = 0;
    let imposedFailure;
    let termination = Promise.resolve();
    const stop = (code, message) => {
      if (imposedFailure) return;
      imposedFailure = new PdfExtractionError(code, message);
      termination = terminateSubprocess(child, grouped).catch(cause => {
        imposedFailure.cleanupError = new PdfExtractionError('cleanup', 'Process-tree cleanup could not be qualified', { cause });
      });
      // Do not wait for an inherited pipe to be closed by a descendant. Other
      // platforms kill the direct child but do not promise process-tree cleanup.
      child.stdout.destroy();
      child.stderr.destroy();
    };
    const timer = setTimeout(() => stop('timeout', `Parser exceeded ${timeoutMs}ms`), timeoutMs);
    const onAbort = () => stop('aborted', 'Extraction was aborted');
    signal?.addEventListener('abort', onAbort, { once: true });
    if (signal?.aborted) onAbort();
    child.stdout.on('data', (data) => {
      bytes += data.length;
      if (bytes > maxOutputBytes) stop('output_limit', `Parser exceeded ${maxOutputBytes} output bytes`);
      else if (!imposedFailure) output.push(data);
    });
    // Drain diagnostics without retaining document contents or scratch paths.
    child.stderr.resume();
    child.once('error', (cause) => { imposedFailure ??= new PdfExtractionError('unavailable', 'Parser could not be executed', { cause }); });
    child.once('close', async (code, terminationSignal) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onAbort);
      await termination;
      if (imposedFailure) reject(imposedFailure);
      else if (terminationSignal) reject(new PdfExtractionError('crashed', `Parser terminated by ${terminationSignal}`));
      else if (code !== 0) reject(new PdfExtractionError('document', `Parser returned exit ${code}`));
      else {
        const buffer = Buffer.concat(output);
        try { resolve(new TextDecoder('utf-8', { fatal: true }).decode(buffer)); }
        catch (cause) { reject(new PdfExtractionError('protocol', 'Parser output is not valid UTF-8', { cause })); }
      }
    });
  });
}

/** Dependency-free, bounded local CLI adapter. The host chooses its binary. */
export async function extractPdfDocument(buffer, options) {
  if (!(buffer instanceof Uint8Array)) throw new TypeError('PDF input must be bytes');
  if (!options || typeof options.binaryPath !== 'string' || !options.binaryPath) throw new TypeError('binaryPath is required');
  const timeoutMs = options.timeoutMs ?? 45_000;
  const maxOutputBytes = options.maxOutputBytes ?? 25 * 1024 * 1024;
  const ocrArgs = ocrArguments(options.ocrLimits);
  if (options.allowPartial !== undefined && typeof options.allowPartial !== 'boolean') throw new TypeError('allowPartial must be a boolean');
  if (!integer(timeoutMs) || timeoutMs < 1 || timeoutMs > 2_147_483_647 || !integer(maxOutputBytes) || maxOutputBytes < 1) throw new RangeError('Invalid extraction limits');
  if (options.signal?.aborted) throw new PdfExtractionError('aborted', 'Extraction was aborted');
  // Own a snapshot before awaiting I/O: a caller can reuse or mutate its buffer.
  const inputBytes = Buffer.from(buffer);
  const inputSha256 = hash(inputBytes);
  let tempDir;
  let failure;
  try {
    tempDir = await mkdtemp(join(tmpdir(), 'pdf-parser-extract-'));
    const inputPath = join(tempDir, 'input.pdf');
    await writeFile(inputPath, inputBytes, { mode: 0o600 });
    const args = ['extract-adaptive', '--input', inputPath, '--source-id', inputSha256, '--format', 'artifact-jsonl', ...ocrArgs];
    if (!options.enableOcr) args.push('--no-ocr');
    if (options.allowPartial) args.push('--allow-partial');
    const rawJsonl = await runParser(options.binaryPath, args, { timeoutMs, maxOutputBytes, signal: options.signal });
    return parseArtifactJsonl(rawJsonl, { inputSha256, expectedSourceId: inputSha256 });
  } catch (error) {
    failure = error instanceof PdfExtractionError ? error : new PdfExtractionError('unavailable', 'Local extraction I/O failed', { cause: error });
    throw failure;
  } finally {
    if (tempDir) {
      try { await rm(tempDir, { recursive: true, force: true }); }
      catch (cause) {
        const cleanupError = new PdfExtractionError('cleanup', 'Could not remove extraction scratch files', { cause });
        if (failure) failure.cleanupError = cleanupError;
        else throw cleanupError;
      }
    }
  }
}

/** Compatibility-shaped string API; uses adaptive block text, not native extract. */
export async function extractPdfText(buffer, options) {
  return (await extractPdfDocument(buffer, options)).sourceText;
}
