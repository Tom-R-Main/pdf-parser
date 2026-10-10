import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { terminateSubprocess } from './subprocess.mjs';

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
  if (!/^0\.(14|15)\.\d+$/.test(manifest.schema_version ?? '') || manifest.schema_name !== 'document_manifest' ||
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
  if (manifest.schema_version.startsWith('0.15.')) {
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
  if (manifest.schema_version.startsWith('0.15.')) {
    const statuses = new Set(['text_available', 'empty_unverified', 'recovery_required', 'recovery_failed', 'recovered']);
    const recoveryStates = new Set(['not_required', 'not_invoked', 'completed', 'empty', 'unavailable', 'failed', 'timeout', 'invalid_output']);
    const failedStates = new Set(['unavailable', 'failed', 'timeout', 'invalid_output']);
    const pageRoutes = new Set();
    for (const record of records.filter(record => record.record_type === 'route_trace' && ['page_route', 'region_route'].includes(record.trace_kind))) {
      const assessment = record.coverage;
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
    const args = ['extract-adaptive', '--input', inputPath, '--source-id', inputSha256, '--format', 'artifact-jsonl'];
    if (!options.enableOcr) args.push('--no-ocr');
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
