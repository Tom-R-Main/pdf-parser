import assert from 'node:assert/strict';
import test from 'node:test';
import { access, mkdtemp, writeFile, rm, readFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractPdfDocument, extractPdfPages, locateSourceRange, composeChunksWithOrigins, parseArtifactJsonl } from './index.mjs';

const binaryPath = fileURLToPath(new URL('../../zig-out/bin/pdf-parser', import.meta.url));
let available = true;
try { await access(binaryPath, constants.X_OK); } catch { available = false; }
const stream = text => `<< /Length ${Buffer.byteLength(text)} >>\nstream\n${text}\nendstream`;
function pdf(objects) {
  let result = '%PDF-1.4\n';
  const offsets = [0];
  for (const [index, object] of objects.entries()) {
    offsets.push(Buffer.byteLength(result));
    result += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = Buffer.byteLength(result);
  result += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) result += `${String(offset).padStart(10, '0')} 00000 n \n`;
  result += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(result, 'ascii');
}
function textPdf(content, resources = '') {
  return pdf(['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 3 0 R >> ${resources} >> /Contents 5 0 R >>`, stream(content),
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 3 0 R >> ${resources} >> /Contents 7 0 R >>`, stream(content)]);
}
async function both(bytes, check) {
  const document = await extractPdfDocument(bytes, { binaryPath });
  check(document, null);
  const pages = [];
  const receipt = await extractPdfPages(bytes, { binaryPath, onPage: page => { check(page, page.pageIndex); pages.push(page); } });
  assert.equal(receipt.complete, true);
  assert.equal(pages.length, document.manifest.page_count);
  return document;
}
function checkLocator(document, phrase) {
  const start = document.sourceText.indexOf(phrase);
  assert.ok(start >= 0, phrase);
  const locator = locateSourceRange(document, start, start + phrase.length, { sourceTextSha256: document.sourceTextSha256 });
  assert.ok(locator.segments.some(segment => segment.sourceSpanId !== null && segment.bbox !== null));
  for (const segment of locator.segments.filter(segment => segment.sourceSpanId !== null)) {
    const span = document.spans.find(span => span.span_id === segment.sourceSpanId);
    assert.equal(document.sourceText.slice(segment.start, segment.end), span.text.slice(segment.sourceStart, segment.sourceEnd));
  }
}

test('ActualText fixture is authoritative in public text, chunks and source locators', { skip: !available }, async () => {
  const bytes = await readFile(new URL('../../benchmark/eval/corpus/weird_fonts/actualtext-repair.pdf', import.meta.url));
  await both(bytes, document => {
    assert.equal(document.sourceText, 'Correct ActualText replacement');
    assert.ok(document.chunks.every(chunk => chunk.content === 'Correct ActualText replacement'));
    assert.ok(!document.rawJsonl.includes('WRONGVISIBLE'));
    checkLocator(document, 'ActualText replacement');
  });
});

test('semantic replacements survive Unicode, operators and paint changes exactly once per page', { skip: !available }, async () => {
  const unicode = 'A 😀 office';
  const hex = Buffer.from(unicode, 'utf16le').swap16().toString('hex');
  const bytes = textPdf(`BT /F1 12 Tf 20 250 Td /Span << /ActualText (ONE REPLACEMENT) >> BDC (raw) Tj 3 Tr [(glyph) 100 (text)] TJ 0 Tr /F1 10 Tf (bad) Tj EMC
0 -30 Td /Span << /ActualText <feff${hex}> >> BDC (wrong) Tj EMC
0 -30 Td /Span << /ActualText () >> BDC (SUPPRESSED) Tj EMC
0 -30 Td (Ordinary suffix) Tj ET`);
  await both(bytes, (document, pageIndex) => {
    const count = pageIndex === null ? 2 : 1;
    assert.equal(document.sourceText.split('ONE REPLACEMENT').length - 1, count);
    assert.equal(document.sourceText.split(unicode).length - 1, count);
    assert.ok(!document.sourceText.includes('SUPPRESSED'));
    assert.ok(!document.sourceText.includes('wrong'));
    checkLocator(document, unicode);
    for (const chunk of composeChunksWithOrigins({ text: document.sourceText, maxTokens: 128, overlapTokens: 10 })) {
      assert.ok(!chunk.body.includes('SUPPRESSED'));
    }
  });
});

test('named marked-content properties retain semantic text and MCID through public adapters', { skip: !available }, async () => {
  const bytes = textPdf('BT /F1 12 Tf 20 250 Td /Span /Replacement BDC (WRONG) Tj EMC ET', '/Properties << /Replacement << /ActualText (Named replacement) /MCID 7 >> >>');
  await both(bytes, (document, pageIndex) => {
    assert.equal(document.sourceText, pageIndex === null ? 'Named replacement\n\nNamed replacement' : 'Named replacement');
    assert.ok(document.spans.every(span => span.mcid === 7));
    checkLocator(document, 'Named replacement');
  });
});

test('PDFDocEncoding replacement text survives both public adapters', { skip: !available }, async () => {
  const bytes = textPdf('BT /F1 12 Tf 20 250 Td /Span << /ActualText <18808d8e9394a07f9fad> >> BDC (WRONG) Tj EMC ET');
  const expected = '˘•“”ﬁﬂ€���';
  await both(bytes, (document, pageIndex) => {
    assert.equal(document.sourceText, pageIndex === null ? `${expected}\n\n${expected}` : expected);
    assert.ok(!document.sourceText.includes('WRONG'));
    checkLocator(document, expected);
  });
});

test('horizontal and rotated writing controls keep boundaries in final chunks', { skip: !available }, async () => {
  for (const matrix of ['1 0 0 1', '.70710678 .70710678 -.70710678 .70710678']) {
    const bytes = textPdf(`BT /F1 12 Tf ${matrix} 100 50 Tm (A) Tj 8.004 0 Td (B) Tj 11.340 0 Td (C) Tj 8.664 0 Td (D) Tj ET`);
    await both(bytes, document => {
      assert.ok(document.chunks.every(chunk => chunk.content.split('\n\n').every(text => text === 'AB CD')));
      assert.ok(!document.sourceText.includes('ABCD'));
      checkLocator(document, 'AB CD');
    });
  }
});

function formPdf(cyclic = false) {
  const body = 'BT /F1 12 Tf 20 280 Td (Body line one has ordinary readable text.) Tj 0 -24 Td (Body line two has ordinary readable text.) Tj 0 -24 Td (Body line three has ordinary readable text.) Tj 0 -24 Td (Body line four has ordinary readable text.) Tj ET\n' +
    'q 1 0 0 1 20 50 cm /One Do Q\nq 1 0 0 1 180 50 cm /Two Do Q\nq 1 0 0 1 100 10 cm /One Do Q';
  const first = cyclic ? '/One Do' : 'BT /F1 12 Tf 5 8 Td /Span << /MCID 0 >> BDC (A) Tj EMC ET';
  const form = (content, extra) => `<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] ${extra} /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`;
  return pdf(['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources 12 0 R /Contents 5 0 R >>', stream(body),
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources 12 0 R /Contents 9 0 R >>',
    form(first, '/Matrix [2 0 0 2 10 20] /Resources 13 0 R'),
    form('BT /F1 12 Tf 5 8 Td /Span << /MCID 0 >> BDC (A) Tj EMC ET', '/Resources << /Font << /F1 11 0 R >> >>'), stream(body),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /B] >> >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /C] >> >>',
    '<< /Font << /F1 3 0 R >> /XObject << /One 7 0 R /Two 8 0 R >> >>',
    '<< /Font << /F1 10 0 R >> /XObject << /One 7 0 R >> >>']);
}

test('Form text uses local resources, matrices and distinct repeated-placement scope without fallback', { skip: !available }, async (t) => {
  const bytes = formPdf();
  await both(bytes, (document, pageIndex) => {
    const page = pageIndex ?? 0;
    const scoped = document.spans.filter(span => span.page_index === page && span.content_scope?.stream_object_num !== null && span.content_scope !== null);
    assert.equal(scoped.length, 3);
    const first = scoped.find(span => span.content_scope.stream_object_num === 7 && span.content_scope.invocation_index === 1);
    const second = scoped.find(span => span.content_scope.stream_object_num === 8);
    assert.equal(first.text, 'B');
    assert.equal(first.bbox.x0, 40);
    assert.ok(first.bbox.x1 > 55 && first.bbox.x1 < 57);
    assert.equal(second.text, 'C');
    assert.equal(second.bbox.x0, 185);
    assert.equal(new Set(scoped.map(span => span.content_scope.invocation_index)).size, 3);
    assert.ok(!document.spans.some(span => span.source === 'poppler_text'));
    checkLocator(document, 'B');
  });
  const directory = await mkdtemp(join(tmpdir(), 'pdf-parser-form-fidelity-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const input = join(directory, 'forms.pdf');
  await writeFile(input, bytes, { mode: 0o600 });
  for (const format of ['artifact-jsonl', 'stream-jsonl']) {
    const output = execFileSync(binaryPath, ['extract-adaptive', '--input', input, '--format', format, '--no-ocr'], {
      env: { ...process.env, PATH: '' }, encoding: 'utf8', timeout: 5000,
    });
    const records = output.trim().split('\n').map(line => JSON.parse(line));
    assert.equal(records.filter(record => record.record_type === 'span' && record.content_scope?.stream_object_num === 7).length, 4);
    if (format === 'artifact-jsonl') assert.ok(parseArtifactJsonl(output, { inputSha256: createHash('sha256').update(bytes).digest('hex') }));
  }
});

test('cyclic Form traversal fails explicitly through both adapters', { skip: !available }, async () => {
  const bytes = formPdf(true);
  await assert.rejects(extractPdfDocument(bytes, { binaryPath }), { code: 'document' });
  let pages = 0;
  await assert.rejects(extractPdfPages(bytes, { binaryPath, onPage: () => { pages++; } }), { code: 'document' });
  assert.equal(pages, 0);
});
