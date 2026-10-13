import assert from 'node:assert/strict';
import { access, readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { composeChunksWithOrigins, extractPdfDocument, extractPdfPages, parseArtifactJsonl, locateSourceRange, projectPromptText } from './index.mjs';

const binaryPath = fileURLToPath(new URL('../../zig-out/bin/pdf-parser', import.meta.url));
let available = true;
try { await access(binaryPath, constants.X_OK); } catch { available = false; }

test('actual CLI without caller source identity keeps every artifact source null', { skip: !available }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-source-contract-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const inputPath = join(directory, 'input.pdf');
  const bytes = fixturePdf();
  await writeFile(inputPath, bytes, { mode: 0o600 });
  const rawJsonl = execFileSync(binaryPath, ['extract-adaptive', '--input', inputPath, '--format', 'artifact-jsonl', '--no-ocr'], { encoding: 'utf8', timeout: 5000 });
  const document = parseArtifactJsonl(rawJsonl, { inputSha256: createHash('sha256').update(bytes).digest('hex'), expectedSourceId: null });
  assert.ok(document.chunks.length > 0);
  for (const record of document.records) {
    assert.equal(record.source_id, null);
    assert.equal(record.provenance.source_id, null);
  }
});

// Small generated, redistribution-safe PDF. Each marked group contains repeated
// lines; a second page checks that origin identity includes the actual page.
function fixturePdf(content = '/Span << /MCID 7 >> BDC BT /F1 12 Tf 20 250 Td (Repeated evidence.) Tj 0 -24 Td (Repeated evidence.) Tj ET EMC') {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>',
    `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 3 0 R >> >> /Contents 7 0 R >>',
    `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`,
  ];
  let pdf = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(pdf));
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) pdf += `${String(offset).padStart(10, '0')} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf, 'ascii');
}

// Reuse the checked-in scan pixels; an incremental update supplies two disjoint
// placements per page without adding a binary fixture or another PDF library.
function repeatedImagePdf(original, pageCount = 1) {
  const content = 'BT /F1 12 Tf 50 740 Td (Native cover text) Tj ET\n' +
    'q 240 0 0 320 20 100 cm /Im1 Do Q\nq 240 0 0 320 300 100 cm /Im1 Do Q';
  const page = '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>';
  const previous = Number(original.toString('latin1').match(/startxref\s+(\d+)\s+%%EOF\s*$/u)[1]);
  const entries = [[2, `<< /Type /Pages /Kids [3 0 R${pageCount === 2 ? ' 7 0 R' : ''}] /Count ${pageCount} >>`],
    [3, page], [4, `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`]];
  if (pageCount === 2) entries.push([7, page]);
  let tail = '\n';
  const offsets = [];
  for (const [id, object] of entries) {
    offsets.push([id, original.length + Buffer.byteLength(tail)]);
    tail += `${id} 0 obj\n${object}\nendobj\n`;
  }
  const xref = original.length + Buffer.byteLength(tail);
  tail += 'xref\n';
  for (const [id, offset] of offsets) tail += `${id} 1\n${String(offset).padStart(10, '0')} 00000 n \n`;
  tail += `trailer\n<< /Size ${pageCount === 2 ? 8 : 7} /Root 1 0 R /Prev ${previous} >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.concat([original, Buffer.from(tail, 'ascii')]);
}

test('actual CLI -> validated rich text -> overlapping chunks -> page/span locators', {
  skip: available ? false : 'Build the parser with zig build to run the real CLI integration',
}, async () => {
  const document = await extractPdfDocument(fixturePdf(), { binaryPath });
  assert.equal(document.manifest.schema_version, '0.19.4');
  assert.equal(document.spans.length, 4);
  assert.equal(document.blocks.length, 4);
  assert.equal(document.sourceText, Array(4).fill('Repeated evidence.').join('\n\n'));
  assert.deepEqual(document.spans.map((span) => span.page_index), [0, 0, 1, 1]);
  const chunks = composeChunksWithOrigins({ text: document.sourceText, maxTokens: 8, overlapTokens: 2 });
  assert.ok(chunks.length > 1);
  assert.ok(chunks.some((chunk, index) => index > 0 && chunk.startOffset < chunks[index - 1].endOffset));
  const spanById = new Map(document.spans.map((span) => [span.span_id, span]));
  const pages = new Set();
  for (const chunk of chunks) {
    assert.equal(document.sourceText.slice(chunk.startOffset, chunk.endOffset).replace(/\s+/gu, ' ').trim(), chunk.body);
    const locator = locateSourceRange(document, chunk.startOffset, chunk.endOffset, { sourceTextSha256: chunk.sourceTextSha256 });
    assert.ok(locator.segments.length > 0);
    for (const segment of locator.segments) {
      if (segment.sourceSpanId === null) { assert.equal(segment.bbox, null); continue; }
      const span = spanById.get(segment.sourceSpanId);
      assert.equal(document.sourceText.slice(segment.start, segment.end), span.text.slice(segment.sourceStart, segment.sourceEnd));
      assert.equal(segment.pageIndex, span.page_index);
      pages.add(segment.pageIndex);
    }
  }
  assert.deepEqual([...pages].sort(), [0, 1]);
  const projection = projectPromptText(document, 10);
  assert.equal(projection.truncated, true);
  assert.equal(document.sourceText.length, 78);
  assert.equal(document.pageCoverage, 'unverified');
});

test('actual financial artifacts retain specialist identities and diagnose legacy table links', {
  skip: available ? false : 'Build the parser with zig build to run the real CLI integration',
}, async () => {
  const pdf = await readFile(new URL('../../benchmark/eval/corpus/financial_tables/complex-financials.pdf', import.meta.url));
  const document = await extractPdfDocument(pdf, { binaryPath });
  assert.ok(document.records.some((record) => record.record_type === 'table'));
  const owners = new Map(document.spans.map(span => [span.span_id, span.reconciled_block_id]));
  for (const table of document.tables) {
    for (const record of [table, ...table.rows.flatMap(row => row.cells)]) {
      assert.deepEqual(new Set(record.reconciled_block_ids), new Set(record.source_span_ids.map(id => owners.get(id)).filter(id => id !== null)));
      for (const id of record.reconciled_block_ids) assert.equal(document.blocks.find(block => block.block_id === id).page_index, record.page_index);
    }
  }
  const requests = document.records.filter((record) => record.record_type === 'specialist_request');
  assert.ok(requests.length > 1);
  assert.equal(new Set(requests.map((record) => record.request_id)).size, requests.length);
  for (const diagnostic of document.unresolvedProvenanceLinks) {
    assert.equal(diagnostic.recordType, 'table');
    assert.equal(diagnostic.field, 'block_ids');
    assert.ok(!document.sourceMap.some((segment) => segment.sourceBlockId === diagnostic.id));
  }
  for (const chunk of composeChunksWithOrigins({ text: document.sourceText, maxTokens: 20, overlapTokens: 5 })) {
    const locator = locateSourceRange(document, chunk.startOffset, chunk.endOffset, { sourceTextSha256: chunk.sourceTextSha256 });
    assert.ok(locator.segments.some((segment) => segment.sourceSpanId !== null));
  }
});

test('actual multi-page stream preserves global ownership with page-local locators', { skip: !available }, async () => {
  const pages = [];
  const receipt = await extractPdfPages(fixturePdf(), { binaryPath, onPage: async page => { pages.push(page); } });
  assert.equal(receipt.complete, true);
  assert.equal(receipt.pageCount, 2);
  assert.equal(receipt.schemaVersion, '0.19.4');
  assert.deepEqual(pages.map(page => page.pageIndex), [0, 1]);
  assert.equal(new Set(pages.flatMap(page => page.spans.map(span => span.span_id))).size, 4);
  for (const page of pages) {
    assert.equal(page.sourceTextScope, 'page');
    assert.equal(page.streamComplete, false);
    assert.equal(page.sourceMap[0].start, 0);
    assert.equal(page.pageOutcomes[0].status, 'text_available');
    assert.equal(page.pageOutcomes[0].completeness, 'unverified');
    const locator = locateSourceRange(page, 0, page.sourceText.length, { sourceTextSha256: page.sourceTextSha256 });
    for (const segment of locator.segments.filter(segment => segment.sourceSpanId !== null)) {
      const span = page.spans.find(span => span.span_id === segment.sourceSpanId);
      assert.equal(span.reconciled_block_id, segment.sourceBlockId);
      assert.deepEqual(span.provenance.block_ids, [segment.sourceBlockId]);
      assert.equal(segment.pageIndex, page.pageIndex);
    }
  }
});

test('actual native page allocation limit fails without delivering a page or receipt', { skip: !available }, async () => {
  let pages = 0;
  await assert.rejects(extractPdfPages(fixturePdf(), { binaryPath, maxNativePageMemoryBytes: 1,
    onPage: () => { pages++; } }), { code: 'memory_limit' });
  assert.equal(pages, 0);
  assert.equal((await extractPdfPages(fixturePdf(), { binaryPath, maxNativePageMemoryBytes: 8 * 1024 * 1024,
    onPage: () => {} })).complete, true);
});

test('actual hidden text specialist contexts bind to global second-page IDs', { skip: !available }, async () => {
  const pages = [];
  const receipt = await extractPdfPages(fixturePdf('BT /F1 12 Tf 3 Tr 20 250 Td (HIDDEN evidence) Tj ET'), {
    binaryPath, onPage: page => pages.push(page),
  });
  assert.equal(receipt.complete, true);
  assert.equal(pages.length, 2);
  for (const page of pages) {
    const requests = page.records.filter(record => record.record_type === 'specialist_request');
    assert.ok(requests.length > 0);
    for (const request of requests) {
      for (const id of request.span_ids) assert.equal(page.spans.find(span => span.span_id === id)?.page_index, page.pageIndex);
      for (const id of request.block_ids) assert.equal(page.blocks.find(block => block.block_id === id)?.page_index, page.pageIndex);
    }
  }
  assert.ok(pages[1].records.some(record => record.record_type === 'specialist_request' && record.span_ids.includes('span-1')));
});

test('actual mixed scan keeps native evidence and exposes disabled recovery', { skip: !available }, async () => {
  const pdf = await readFile(new URL('../../benchmark/eval/corpus/scanned_typewritten/mixed-native-scan.pdf', import.meta.url));
  const document = await extractPdfDocument(pdf, { binaryPath });
  assert.ok(document.sourceText.includes('Native cover text'));
  assert.equal(document.pageOutcomes.length, document.manifest.page_count);
  const outcome = document.pageOutcomes[0];
  assert.equal(outcome.status, 'recovery_required');
  assert.equal(outcome.requested_recovery, true);
  assert.equal(outcome.recovery_state, 'not_invoked');
  assert.equal(outcome.completeness, 'unverified');
  assert.ok(outcome.native_span_count > 0);
});

test('actual public artifacts preserve nonpainting and clipped text with transformed evidence', { skip: !available }, async () => {
  const bytes = fixturePdf(`BT /F1 12 Tf 20 260 Td (VISIBLE) Tj ET
    q BT /F1 12 Tf 3 Tr 20 230 Td (HIDDEN) Tj ET Q
    q 0 0 40 40 re W n BT /F1 12 Tf 180 180 Td (CLIPPED) Tj ET Q
    q 2 0 0 2 30 40 cm 0 0 50 50 re W n BT /F1 12 Tf 10 10 Td (TRANSFORMED) Tj ET Q`);
  const document = await extractPdfDocument(bytes, { binaryPath });
  for (const text of ['VISIBLE', 'HIDDEN', 'CLIPPED', 'TRANSFORMED']) assert.ok(document.sourceText.includes(text));
  const hidden = document.spans.find(span => span.text.includes('HIDDEN'));
  assert.equal(hidden.paint.rendering_mode, 3);
  assert.equal(hidden.paint.paint_state, 'non_painting');
  const clipped = document.spans.find(span => span.text.includes('CLIPPED'));
  assert.equal(clipped.paint.clip_state, 'outside');
  const transformed = document.spans.filter(span => span.page_index === 0 && span.paint.clip_bbox?.x0 === 30 && span.paint.clip_bbox?.y0 === 40);
  assert.equal(transformed.map(span => span.text).join(''), 'TRANSFORMED');
  assert.ok(transformed.every(span => JSON.stringify(span.paint.clip_bbox) === JSON.stringify({ x0: 30, y0: 40, x1: 130, y1: 140 })));
  assert.equal(transformed[0].bbox.x0, 50);
  assert.ok(document.pageOutcomes.every(outcome => outcome.non_painting_span_count > 0 && outcome.clipped_out_span_count > 0 && outcome.completeness === 'unverified'));
  let pages = 0;
  assert.equal((await extractPdfPages(bytes, { binaryPath, onPage(page) {
    assert.ok(page.spans.some(span => span.paint.paint_state === 'non_painting'));
    pages++;
  } })).complete, true);
  assert.equal(pages, 2);
});

test('actual regional OCR binds crop identity and budgets, preserving native text on refusal', { skip: !available }, async () => {
  const pdf = await readFile(new URL('../../benchmark/eval/corpus/scanned_typewritten/mixed-native-scan.pdf', import.meta.url));
  const document = await extractPdfDocument(pdf, { binaryPath, enableOcr: true });
  assert.ok(document.sourceText.includes('Native cover text'));
  assert.ok(document.sourceText.includes('SCANNED TYPEWRITTEN'));
  assert.equal(document.pageOutcomes[0].status, 'recovered');
  const attempts = document.records.filter(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr');
  assert.ok(attempts.length > 0);
  for (const attempt of attempts) {
    assert.ok(Number.isInteger(attempt.region_index));
    assert.match(attempt.crop.image_sha256, /^[a-f0-9]{64}$/u);
    assert.ok(attempt.crop.image_byte_length > 24);
    assert.ok(attempt.crop.pixel_width * attempt.crop.pixel_height <= attempt.config.max_image_pixels);
  }
  await assert.rejects(extractPdfDocument(pdf, { binaryPath, enableOcr: true, ocrLimits: { maxImagePixels: 1 } }), { code: 'document' });
  const partial = await extractPdfDocument(pdf, { binaryPath, enableOcr: true, allowPartial: true, ocrLimits: { maxImagePixels: 1 } });
  assert.ok(partial.sourceText.includes('Native cover text'));
  assert.equal(partial.pageOutcomes[0].status, 'recovery_failed');
  assert.equal(partial.pageOutcomes[0].completeness, 'unverified');
  assert.ok(partial.records.some(record => record.record_type === 'specialist_attempt' && record.errors.some(error => error.code === 'rasterizer_pixel_limit')));
});

test('actual independent image crops retain quota failures and stream global OCR identities', { skip: !available }, async () => {
  const original = await readFile(new URL('../../benchmark/eval/corpus/scanned_typewritten/mixed-native-scan.pdf', import.meta.url));
  const quota = await extractPdfDocument(repeatedImagePdf(original), { binaryPath, enableOcr: true, allowPartial: true,
    timeoutMs: 120000, ocrLimits: { maxRegionsPerPage: 1 } });
  const images = quota.records.filter(record => record.record_type === 'route_trace' && record.trace_kind === 'region_route' && record.layout_block_index === null && record.image_count === 1);
  assert.equal(images.length, 2);
  assert.deepEqual(images.map(record => record.bbox), [{ x0: 20, y0: 100, x1: 260, y1: 420 }, { x0: 300, y0: 100, x1: 540, y1: 420 }]);
  const attempts = quota.records.filter(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr');
  assert.ok(attempts.some(attempt => attempt.region_index === images[0].region_index && attempt.selected));
  assert.ok(attempts.some(attempt => attempt.region_index === images[1].region_index && attempt.attempt_status === 'not_invoked' && [...attempt.warnings, ...attempt.errors].some(diagnostic => diagnostic.code === 'ocr_region_limit')));
  assert.equal(quota.pageOutcomes[0].status, 'recovery_required');
  assert.equal(quota.pageOutcomes[0].completeness, 'unverified');
  assert.ok(quota.sourceText.includes('Native cover text'));

  const attemptQuota = await extractPdfDocument(repeatedImagePdf(original), { binaryPath, enableOcr: true, allowPartial: true,
    timeoutMs: 120000, ocrLimits: { maxAttemptsPerPage: 1 } });
  assert.ok(attemptQuota.records.some(record => record.record_type === 'specialist_attempt' && record.attempt_status === 'not_invoked' &&
    [...record.warnings, ...record.errors].some(diagnostic => diagnostic.code === 'ocr_attempt_limit')));
  assert.equal(attemptQuota.pageOutcomes[0].status, 'recovery_required');
  assert.ok(attemptQuota.sourceText.includes('Native cover text'));

  const pages = [];
  const receipt = await extractPdfPages(repeatedImagePdf(original, 2), { binaryPath, enableOcr: true, timeoutMs: 120000,
    onPage: page => pages.push(page) });
  assert.equal(receipt.complete, true);
  assert.equal(pages.length, 2);
  const identities = pages.flatMap(page => page.records.filter(record => record.record_type === 'specialist_attempt').map(record => record.attempt_id));
  assert.equal(new Set(identities).size, identities.length);
  for (const page of pages) {
    assert.equal(page.pageOutcomes[0].status, 'recovered');
    assert.ok(page.sourceText.includes('Native cover text'));
    assert.ok(page.sourceText.includes('SCANNED'));
    const results = page.records.filter(record => record.record_type === 'specialist_result' && record.specialist_kind === 'ocr');
    assert.equal(results.length, 2);
    for (const result of results) {
      assert.ok(result.span_ids.length > 0);
      assert.ok(result.span_ids.every(id => page.spans.some(span => span.span_id === id && span.page_index === page.pageIndex)));
    }
  }
});
