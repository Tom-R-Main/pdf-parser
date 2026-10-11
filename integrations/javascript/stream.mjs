import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArtifactJsonl, PdfExtractionError } from './extract.mjs';
import { terminateSubprocess } from './subprocess.mjs';
import { ocrArguments } from './ocr-options.mjs';

const integer = (value) => Number.isSafeInteger(value) && value >= 0;
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const countFields = { span: 'spans', block: 'blocks', table: 'tables', route_trace: 'route_traces',
  specialist_request: 'specialist_requests', specialist_attempt: 'specialist_attempts',
  specialist_response: 'specialist_responses', specialist_result: 'specialist_results',
  rag_chunk: 'rag_chunks', debug_asset: 'debug_assets' };
const emptyCounts = () => Object.fromEntries(Object.values(countFields).map((key) => [key, 0]));
const routeKeys = ['native_pages', 'page_routes', 'region_routes', 'ocr_regions', 'table_regions', 'formula_regions'];
const fail = (message) => { throw new PdfExtractionError('protocol', message); };
const checkCounts = (actual, expected) => {
  if (!object(actual) || Object.keys(expected).some((key) => actual[key] !== expected[key])) fail('Stream artifact count mismatch');
};

async function consume(binaryPath, args, options, inputSha256) {
  const grouped = process.platform !== 'win32';
  const child = spawn(binaryPath, args, { stdio: ['ignore', 'pipe', 'pipe'], detached: grouped, windowsHide: true });
  let failure;
  let termination = Promise.resolve();
  let rejectFailure;
  const failed = new Promise((_, reject) => { rejectFailure = reject; });
  failed.catch(() => {});
  const stop = (error) => {
    if (failure) return;
    failure = error;
    termination = terminateSubprocess(child, grouped).catch(cause => {
      failure.cleanupError = new PdfExtractionError('cleanup', 'Process-tree cleanup could not be qualified', { cause });
    });
    child.stdout.destroy();
    child.stderr.destroy();
    rejectFailure(error);
  };
  const closed = new Promise((resolve) => {
    child.once('error', (cause) => stop(new PdfExtractionError('unavailable', 'Parser could not be executed', { cause })));
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  let nativeFailure;
  let diagnosticTail = '';
  child.stderr.on('data', bytes => {
    diagnosticTail = (diagnosticTail + bytes.toString('utf8')).slice(-256);
    if (diagnosticTail.includes('MemoryBudgetExceeded')) nativeFailure = new PdfExtractionError('memory_limit', 'Native adaptive page allocation budget exceeded');
    else if (diagnosticTail.includes('OutputLimitExceeded')) nativeFailure ??= new PdfExtractionError('output_limit', 'Native serialized output budget exceeded');
  });
  const timer = setTimeout(() => stop(new PdfExtractionError('timeout', 'Streaming extraction exceeded its deadline')), options.timeoutMs);
  const abort = () => stop(new PdfExtractionError('aborted', 'Extraction was aborted'));
  options.signal?.addEventListener('abort', abort, { once: true });
  if (options.signal?.aborted) abort();
  const totals = emptyCounts();
  const routeTotals = Object.fromEntries(routeKeys.map((key) => [key, 0]));
  const identities = new Set();
  let manifest;
  let currentPage = null;
  let pageCount = 0;
  let pageBytes = 0;
  let pageLines = [];
  let pageCounts = emptyCounts();
  let records = 0;
  let outputBytes = 0;
  let finished = false;
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const line = async (buffer) => {
    if (++records > options.maxRecords) throw new PdfExtractionError('output_limit', 'Stream exceeded its record budget');
    let raw;
    let record;
    try { raw = decoder.decode(buffer); record = JSON.parse(raw); }
    catch (cause) { throw new PdfExtractionError('protocol', 'Malformed UTF-8 JSONL record', { cause }); }
    if (finished) fail('Record follows document completion');
    const type = record?.record_type;
    if (!object(record) || record.event_index !== records - 1 || record.event_type !== type || record.schema_name !== type) fail('Invalid stream event sequence');
    const firstRecord = !manifest;
    if (firstRecord) {
      if (type !== 'document_manifest' || record.streaming !== true || record.sequence_scope !== 'document' ||
        !/^0\.(14|15|16|17|18|19)\.\d+$/.test(record.schema_version ?? '') || !integer(record.page_count) ||
        typeof record.document_id !== 'string' || !record.document_id || record.input_sha256 !== inputSha256 || record.source_id !== inputSha256) fail('Invalid stream manifest');
      if (record.page_count > options.maxPages) throw new PdfExtractionError('output_limit', 'Stream exceeded its page-count budget');
      if (!Array.isArray(record.errors) || record.errors.length) fail('Stream manifest reports document errors');
      manifest = record;
      // Also validate an empty document: there may be no page on which the
      // richer batch validator can otherwise check the text contract.
      parseArtifactJsonl(JSON.stringify({ ...manifest, artifact_counts: emptyCounts() }) + '\n', { inputSha256, expectedSourceId: inputSha256 });
    }
    const provenance = record.provenance;
    const specialField = { specialist_request: 'request_id', specialist_attempt: 'attempt_id',
      specialist_response: 'response_id', specialist_result: 'specialist_result_id' }[type];
    const id = specialField ? record[specialField] : provenance?.artifact_id;
    if (record.schema_version !== manifest.schema_version || record.document_id !== manifest.document_id || record.source_id !== inputSha256 ||
      !object(provenance) || provenance.document_id !== manifest.document_id || provenance.source_id !== inputSha256 || provenance.input_sha256 !== inputSha256 ||
      typeof provenance.artifact_id !== 'string' || !provenance.artifact_id || typeof id !== 'string' || !id || identities.has(id)) fail('Invalid stream identity');
    identities.add(id);
    if (type === 'document_manifest') {
      if (!firstRecord) fail('Duplicate stream manifest');
      return;
    }
    if (type === 'page_started') {
      if (currentPage !== null || record.page_index !== pageCount || pageCount >= manifest.page_count || record.sequence_scope !== 'page' || record.status !== 'running') fail('Invalid page start');
      currentPage = record.page_index;
      pageBytes = buffer.length + 1;
      pageLines = [];
      pageCounts = emptyCounts();
    } else if (type === 'page_finished') {
      if (currentPage === null || record.page_index !== currentPage || record.sequence_scope !== 'page' || record.status !== 'completed') fail('Invalid page completion');
      checkCounts(record.artifact_counts, pageCounts);
      if (!object(record.route_counts) || routeKeys.some((key) => !integer(record.route_counts[key]))) fail('Invalid page route counts');
      for (const key of routeKeys) {
        routeTotals[key] += record.route_counts[key];
        if (!integer(routeTotals[key])) fail('Route count overflow');
      }
      pageBytes += buffer.length + 1;
      if (pageBytes > options.maxPageBytes) throw new PdfExtractionError('output_limit', 'Stream exceeded its page budget');
      const batchManifest = { ...manifest, streaming: false, artifact_counts: pageCounts };
      const document = parseArtifactJsonl([JSON.stringify(batchManifest), ...pageLines].join('\n') + '\n', { inputSha256, expectedSourceId: inputSha256 });
      // This projection has page-local offsets even though artifact IDs and page
      // indices remain document-global. Delivered pages are provisional until
      // the final receipt; callbacks must not treat delivery as completion.
      const page = { ...document, pageIndex: currentPage, sourceTextScope: 'page', streamComplete: false };
      pageLines = [];
      try { await Promise.race([Promise.resolve().then(() => options.onPage(page)), failed]); }
      catch (cause) {
        if (failure) throw failure;
        throw new PdfExtractionError('callback', 'Page callback failed', { cause });
      }
      pageCount++;
      currentPage = null;
    } else if (type === 'document_finished') {
      if (currentPage !== null || pageCount !== manifest.page_count || record.sequence_scope !== 'document' || record.status !== 'completed' ||
        !Array.isArray(record.errors) || record.errors.length) fail('Invalid document completion');
      checkCounts(record.artifact_counts, totals);
      checkCounts(record.route_counts, routeTotals);
      finished = true;
    } else {
      const field = countFields[type];
      if (!field) fail('Unsupported streaming artifact');
      if (currentPage !== null) {
        if (record.sequence_scope !== 'page' || (type === 'rag_chunk' ? record.page_start !== currentPage || record.page_end !== currentPage : record.page_index !== currentPage)) fail('Artifact page mismatch');
        pageBytes += buffer.length + 1;
        if (pageBytes > options.maxPageBytes) throw new PdfExtractionError('output_limit', 'Stream exceeded its page budget');
        pageLines.push(raw);
        pageCounts[field]++;
      } else if (type !== 'debug_asset' || record.sequence_scope !== 'document' ||
        ['span_ids', 'block_ids', 'chunk_ids'].some((key) => provenance[key]?.length)) fail('Artifact outside page lifecycle');
      totals[field]++;
    }
    if (pageBytes > options.maxPageBytes) throw new PdfExtractionError('output_limit', 'Stream exceeded its page budget');
  };
  try {
    let pending = Buffer.alloc(0);
    for await (const chunk of child.stdout) {
      if (failure) throw failure;
      outputBytes += chunk.length;
      if (outputBytes > options.maxOutputBytes) throw new PdfExtractionError('output_limit', 'Stream exceeded its aggregate output budget');
      let start = 0;
      while (start < chunk.length) {
        const newline = chunk.indexOf(10, start);
        const end = newline < 0 ? chunk.length : newline;
        if (pending.length + end - start > options.maxRecordBytes) throw new PdfExtractionError('output_limit', 'Stream exceeded its record byte budget');
        const part = chunk.subarray(start, end);
        if (newline < 0) { pending = Buffer.concat([pending, part]); break; }
        const recordBytes = pending.length ? Buffer.concat([pending, part]) : part;
        pending = Buffer.alloc(0);
        await line(recordBytes);
        start = newline + 1;
      }
    }
    if (failure) throw failure;
    const result = await Promise.race([closed, failed]);
    if (result.signal) throw new PdfExtractionError('crashed', `Parser terminated by ${result.signal}`);
    if (result.code !== 0) throw nativeFailure ?? new PdfExtractionError('document', `Parser returned exit ${result.code}`);
    if (pending.length) fail('Truncated JSONL record');
    if (!finished) fail('Stream ended before document completion');
    return { complete: true, inputSha256, schemaVersion: manifest.schema_version, pageCount, records, outputBytes, artifactCounts: totals };
  } catch (error) {
    stop(error instanceof PdfExtractionError ? error : new PdfExtractionError('protocol', 'Streaming extraction failed', { cause: error }));
    await closed;
    await termination;
    throw failure;
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', abort);
  }
}

/** Incremental local CLI adapter. Memory budgets cover retained JSONL and IDs,
 * not the parser's RSS or data the caller retains inside its callback. */
export async function extractPdfPages(buffer, options) {
  if (!(buffer instanceof Uint8Array)) throw new TypeError('PDF input must be bytes');
  if (!options || typeof options.binaryPath !== 'string' || !options.binaryPath || typeof options.onPage !== 'function') throw new TypeError('binaryPath and onPage are required');
  const defaults = { timeoutMs: 45_000, maxOutputBytes: 25 * 1024 * 1024, maxPageBytes: 4 * 1024 * 1024,
    maxRecordBytes: 1024 * 1024, maxRecords: 100_000, maxPages: 10_000 };
  const limits = { ...options };
  const ocrArgs = ocrArguments(options.ocrLimits);
  if (options.allowPartial !== undefined && typeof options.allowPartial !== 'boolean') throw new TypeError('allowPartial must be a boolean');
  for (const [key, defaultValue] of Object.entries(defaults)) {
    limits[key] ??= defaultValue;
    if (!integer(limits[key]) || limits[key] < 1 || (key === 'timeoutMs' && limits[key] > 2_147_483_647)) throw new RangeError('Invalid streaming limits');
  }
  if (options.signal?.aborted) throw new PdfExtractionError('aborted', 'Extraction was aborted');
  if (options.maxNativePageMemoryBytes !== undefined && (!integer(options.maxNativePageMemoryBytes) || options.maxNativePageMemoryBytes < 1)) throw new RangeError('Invalid native page allocation budget');
  const input = Buffer.from(buffer);
  const inputSha256 = createHash('sha256').update(input).digest('hex');
  let directory;
  let failure;
  try {
    directory = await mkdtemp(join(tmpdir(), 'pdf-parser-stream-'));
    const path = join(directory, 'input.pdf');
    await writeFile(path, input, { mode: 0o600 });
    const args = ['extract-adaptive', '--input', path, '--source-id', inputSha256, '--format', 'stream-jsonl', ...ocrArgs];
    if (options.maxNativePageMemoryBytes !== undefined) args.push('--max-page-memory-bytes', String(options.maxNativePageMemoryBytes));
    if (!options.enableOcr) args.push('--no-ocr');
    if (options.allowPartial) args.push('--allow-partial');
    return await consume(options.binaryPath, args, limits, inputSha256);
  } catch (error) {
    failure = error instanceof PdfExtractionError ? error : new PdfExtractionError('unavailable', 'Local streaming I/O failed', { cause: error });
    throw failure;
  } finally {
    if (directory) {
      try { await rm(directory, { recursive: true, force: true }); }
      catch (cause) {
        const cleanup = new PdfExtractionError('cleanup', 'Could not remove streaming scratch files', { cause });
        if (failure) failure.cleanupError = cleanup;
        else throw cleanup;
      }
    }
  }
}
