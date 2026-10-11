import assert from 'node:assert/strict';
import test from 'node:test';
import { access, readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractPdfDocument, extractPdfPages, parseArtifactJsonl, locateSourceRange,
  getPageGeometry, mapPdfBBoxToDisplay, mapDisplayBBoxToPdf } from './index.mjs';

const binaryPath = fileURLToPath(new URL('../../zig-out/bin/pdf-parser', import.meta.url));
let available = true;
try { await access(binaryPath, constants.X_OK); } catch { available = false; }
const scan = await readFile(new URL('./fixtures/quarter-scan.jpg', import.meta.url));
const boxes = [[10, 20, 310, 220], [10, 20, 210, 320], [10, 20, 310, 220], [10, 20, 210, 320]];
const placements = [[300, 0, 0, 200, 10, 20], [0, 300, -200, 0, 210, 20],
  [-300, 0, 0, -200, 310, 220], [0, -300, 200, 0, 10, 320]];
// Pixels are generated text, counter-rotated so each rendered page is upright.
// This tests coordinate recovery, rather than automatic orientation detection.
function scanPdf(rotation, userUnit = 1, crop = null) {
  const quarter = rotation / 90;
  const content = `q ${placements[quarter].join(' ')} cm /Im1 Do Q`;
  const image = Buffer.concat([Buffer.from(`<< /Type /XObject /Subtype /Image /Width 600 /Height 400 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${scan.length} >>\nstream\n`), scan, Buffer.from('\nendstream')]);
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [${boxes[quarter].join(' ')}] /Rotate ${rotation} /UserUnit ${userUnit} ${crop ? `/CropBox [${crop.join(' ')}]` : ''} /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>`,
    `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`, image];
  return pdfObjects(objects);
}
function pdfObjects(objects) {
  const parts = [Buffer.from('%PDF-1.7\n')];
  const offsets = [];
  let length = parts[0].length;
  for (const [index, object] of objects.entries()) {
    offsets.push(length);
    const bytes = Buffer.concat([Buffer.from(`${index + 1} 0 obj\n`), Buffer.from(object), Buffer.from('\nendobj\n')]);
    parts.push(bytes); length += bytes.length;
  }
  const xref = length;
  parts.push(Buffer.from(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`));
  return Buffer.concat(parts);
}
function closeBox(actual, expected, tolerance = 0.02) {
  for (const [index, key] of ['x0', 'y0', 'x1', 'y1'].entries()) assert.ok(Math.abs(actual[key] - expected[index]) <= tolerance, `${key}: ${actual[key]} != ${expected[index]}`);
}
function checkText(document) {
  assert.ok(document.sourceText.includes('QUARTER TURN EVIDENCE'), document.sourceText);
  assert.ok(document.chunks.some(chunk => chunk.content.includes('QUARTER TURN EVIDENCE')));
  const start = document.sourceText.indexOf('QUARTER');
  const locator = locateSourceRange(document, start, start + 7, { sourceTextSha256: document.sourceTextSha256 });
  assert.ok(locator.segments.some(segment => segment.sourceSpanId && segment.bbox));
  return document.spans.find(span => span.text === 'QUARTER');
}

test('actual quarter-turn OCR round-trips raster words into raw PDF coordinates', { skip: !available }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-quarters-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  // Independent Poppler/Tesseract144-DPI measurements, not calculated by helpers.
  const expected = [[31, 170.5, 116, 185], [45, 41, 59.5, 126], [204, 55, 289, 69.5], [160.5, 214, 175, 299]];
  for (const [quarter, rotation] of [0, 90, 180, 270].entries()) {
    const bytes = scanPdf(rotation);
    const path = join(directory, `quarter-${rotation}.pdf`);
    await writeFile(path, bytes);
    const rawJsonl = execFileSync(binaryPath, ['extract-adaptive', '--input', path, '--format', 'artifact-jsonl', '--ocr-dpi', '144', '--ocr-policy', 'single'], { encoding: 'utf8', timeout: 30000 });
    const document = parseArtifactJsonl(rawJsonl, { inputSha256: createHash('sha256').update(bytes).digest('hex') });
    const word = checkText(document);
    closeBox(word.bbox, expected[quarter]);
    const geometry = getPageGeometry(document, 0);
    assert.equal(geometry.rotation_degrees, rotation);
    const display = mapPdfBBoxToDisplay(word.bbox, geometry, { scale: 2 });
    closeBox(display, [42, 70, 212, 99]);
    closeBox(mapDisplayBBoxToPdf(display, geometry, { scale: 2 }), expected[quarter]);
    const attempt = document.records.find(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr' && record.selected);
    assert.equal(attempt.raster_transform.rasterizer_dpi, 144);
    assert.equal(attempt.execution.pixel_width, 600);
    assert.equal(attempt.execution.pixel_height, 400);
    const pages = [];
    const receipt = await extractPdfPages(bytes, { binaryPath, enableOcr: true, onPage: page => pages.push(page) });
    assert.equal(receipt.complete, true);
    checkText(pages[0]);
    assert.equal(getPageGeometry(pages[0], 0).rotation_degrees, rotation);
  }
});

test('UserUnit scales physical raster and CropBox display without changing raw source boxes', { skip: !available }, async () => {
  const bytes = scanPdf(90, 2, [30, 40, 190, 300]);
  const document = await extractPdfDocument(bytes, { binaryPath, enableOcr: true });
  const word = checkText(document);
  const geometry = getPageGeometry(document, 0);
  assert.equal(geometry.user_unit, 2);
  assert.equal(geometry.display.width, 520);
  assert.equal(geometry.display.height, 320);
  const attempt = document.records.find(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr' && record.selected);
  assert.equal(attempt.raster_transform.rasterizer_dpi, 400);
  closeBox(word.bbox, [45, 41, 59.5, 126], 1.5);
  const display = mapPdfBBoxToDisplay(word.bbox, geometry, { scale: 1.5 });
  closeBox(mapDisplayBBoxToPdf(display, geometry, { scale: 1.5 }), [word.bbox.x0, word.bbox.y0, word.bbox.x1, word.bbox.y1]);
  const refused = await extractPdfDocument(bytes, { binaryPath, enableOcr: true, allowPartial: true, ocrLimits: { maxImagePixels: 1 } });
  assert.ok(refused.records.some(record => record.record_type === 'specialist_attempt' && record.errors.some(error => error.code === 'rasterizer_pixel_limit')));
  assert.equal(refused.pageOutcomes[0].completeness, 'unverified');
});

test('actual formula crops share quarter-turn transforms and remove ephemeral images', { skip: !available }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-formula-quarters-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const childPath = join(directory, 'child.mjs');
  const evidencePath = join(directory, 'child.json');
  await writeFile(childPath, `import { readFileSync, writeFileSync } from 'node:fs';
const request = JSON.parse(readFileSync(0, 'utf8'));
const image = readFileSync(request.crop_image_path);
const transform = request.crop_geometry;
if (!transform || transform.pixel_to_pdf.length !== 6 || image.length <= 24 || image.readUInt32BE(16) !== transform.pixel_width || image.readUInt32BE(20) !== transform.pixel_height) process.exit(7);
writeFileSync(process.argv[2], JSON.stringify({ request, bytes: image.length }));
process.stdout.write(JSON.stringify({ schema_version: request.schema_version, record_type: 'specialist_response', request_id: request.request_id, specialist_id: 'coordinate-fixture', specialist_kind: 'formula', status: 'completed', formulas: [{ text: 'x^2+y^2=z^2', format: 'latex', confidence: 0.95 }] }) + '\\n');
`);
  const configPath = join(directory, 'config.json');
  await writeFile(configPath, JSON.stringify({ formula: { enabled: true, executable: process.execPath,
    args: [childPath, evidencePath], crop_dpi: 144, crop_grayscale: false } }));
  for (const rotation of [0, 90, 180, 270]) {
    const content = 'BT /F1 12 Tf 1 0 0 1 100 240 Tm (E=mc^2++++////^^^^____) Tj 1 0 0 1 100 220 Tm (alpha+beta/gamma====) Tj 1 0 0 1 100 200 Tm (sum\\(x_i^2\\)>=delta++++) Tj ET';
    const bytes = pdfObjects(['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      `<< /Type /Page /Parent 2 0 R /MediaBox [10 20 410 320] /Rotate ${rotation} /UserUnit 2 /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>`,
      `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']);
    const path = join(directory, 'input.pdf');
    await writeFile(path, bytes);
    for (const format of ['artifact-jsonl', 'stream-jsonl']) {
      const raw = execFileSync(binaryPath, ['extract-adaptive', '--input', path, '--format', format, '--no-ocr', '--specialist-config', configPath], { encoding: 'utf8', timeout: 30000 });
      const records = raw.trim().split('\n').map(JSON.parse);
      const attempt = records.find(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'formula' && record.attempt_status === 'completed');
      assert.ok(attempt, `rotation${rotation} ${format}`);
      assert.equal(attempt.config.crop_transform.rasterizer_dpi, 288);
      const evidence = JSON.parse(await readFile(evidencePath, 'utf8'));
      assert.equal(evidence.request.crop_geometry.rasterizer_dpi, 288);
      assert.ok(evidence.bytes > 24);
      await assert.rejects(access(evidence.request.crop_image_path), { code: 'ENOENT' });
      assert.ok(records.some(record => record.record_type === 'span' && record.text === 'x^2+y^2=z^2'));
      if (format === 'artifact-jsonl') parseArtifactJsonl(raw, { inputSha256: createHash('sha256').update(bytes).digest('hex') });
    }
  }
});

test('quarter-turn OCR grid retains engine rows before derived table promotion', { skip: !available }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-ocr-grid-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const engine = join(directory, 'engine.sh');
  const rows = ['level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext'];
  for (let row = 1; row <= 4; row++) for (let column = 1; column <= 2; column++) {
    rows.push(`5\t1\t1\t1\t${row}\t${column}\t${column === 1 ? 20 : 170}\t${20 + (row - 1) * 30}\t70\t12\t99\tR${row}C${column}`);
  }
  await writeFile(engine, `#!/bin/sh\ncat <<'TSV'\n${rows.join('\n')}\nTSV\n`, { mode: 0o700 });
  const expected = 'R1C1 R1C2\nR2C1 R2C2\nR3C1 R3C2\nR4C1 R4C2';
  for (const rotation of [0, 90, 180, 270]) {
    const bytes = scanPdf(rotation);
    const path = join(directory, 'input.pdf');
    await writeFile(path, bytes);
    for (const format of ['artifact-jsonl', 'stream-jsonl']) {
      const raw = execFileSync(binaryPath, ['extract-adaptive', '--input', path, '--format', format, '--ocr-dpi', '144', '--ocr-policy', 'single', '--ocr-executable', engine], { encoding: 'utf8', timeout: 30000 });
      const records = raw.trim().split('\n').map(JSON.parse);
      assert.equal(records.filter(record => record.record_type === 'rag_chunk').map(record => record.content).join('\n\n'), expected, `rotation${rotation} ${format}`);
      if (rotation !== 0) {
        assert.ok(records.filter(record => record.record_type === 'span').every(span => span.source === 'fresh_ocr'));
        assert.ok(!records.some(record => record.record_type === 'table'));
      }
      if (format === 'artifact-jsonl') {
        const document = parseArtifactJsonl(raw, { inputSha256: createHash('sha256').update(bytes).digest('hex') });
        assert.equal(document.sourceText, expected);
        const start = document.sourceText.indexOf('R2C2');
        const locator = locateSourceRange(document, start, start + 4, { sourceTextSha256: document.sourceTextSha256 });
        assert.ok(locator.segments.every(segment => segment.sourceSpanId && segment.bbox));
      }
    }
  }
});

test('actual regional crop at a large origin retains native and OCR source evidence', { skip: !available }, async () => {
  const origin = 10000;
  const content = `BT /F1 12 Tf 1 0 0 1 ${origin + 20} ${origin + 370} Tm (Native cover text provides reliable source evidence.) Tj ET\nq 300 0 0 200 ${origin + 30} ${origin + 40} cm /Im1 Do Q`;
  const image = Buffer.concat([Buffer.from(`<< /Type /XObject /Subtype /Image /Width 600 /Height 400 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${scan.length} >>\nstream\n`), scan, Buffer.from('\nendstream')]);
  const bytes = pdfObjects(['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [${origin} ${origin} ${origin + 400} ${origin + 400}] /CropBox [${origin + 10} ${origin + 20} ${origin + 390} ${origin + 390}] /UserUnit 2 /Resources << /XObject << /Im1 5 0 R >> /Font << /F1 6 0 R >> >> /Contents 4 0 R >>`,
    `<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`, image,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']);
  function check(document) {
    const word = checkText(document);
    assert.ok(document.sourceText.includes('Native cover text'));
    assert.ok(word.bbox.x0 > origin && word.bbox.y0 > origin);
    const attempt = document.records.find(record => record.record_type === 'specialist_attempt' && record.specialist_kind === 'ocr' && record.selected);
    assert.ok(Number.isInteger(attempt.region_index));
    assert.equal(attempt.raster_transform.rasterizer_dpi, 400);
    const geometry = getPageGeometry(document, 0);
    const mapped = mapPdfBBoxToDisplay(word.bbox, geometry, { scale: 1.25 });
    closeBox(mapDisplayBBoxToPdf(mapped, geometry, { scale: 1.25 }), Object.values(word.bbox));
  }
  check(await extractPdfDocument(bytes, { binaryPath, enableOcr: true }));
  const receipt = await extractPdfPages(bytes, { binaryPath, enableOcr: true, onPage: check });
  assert.equal(receipt.complete, true);
});
