import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { composeChunksWithOrigins } from './chunk-origins.mjs';

const normalize = (text) => text.replace(/\s+/gu, ' ').trim();
function assertOrigins(text, chunks) {
  const hash = createHash('sha256').update(text, 'utf8').digest('hex');
  for (const [index, chunk] of chunks.entries()) {
    assert.equal(chunk.index, index);
    assert.equal(normalize(text.slice(chunk.startOffset, chunk.endOffset)), chunk.body);
    assert.equal(chunk.sourceTextSha256, hash);
    assert.equal(chunk.offsetUnit, 'utf16_code_unit');
    assert.ok(chunk.startOffset >= 0 && chunk.endOffset <= text.length && chunk.endOffset > chunk.startOffset);
    assert.ok(!(/[\uD800-\uDBFF]/u.test(text[chunk.startOffset - 1] ?? '') && /[\uDC00-\uDFFF]/u.test(text[chunk.startOffset] ?? '')));
    assert.ok(!(/[\uD800-\uDBFF]/u.test(text[chunk.endOffset - 1] ?? '') && /[\uDC00-\uDFFF]/u.test(text[chunk.endOffset] ?? '')));
  }
}

test('retains original leading whitespace, collapsed runs, and untrimmed source identity', () => {
  const text = '  \tA   😀\n\nB C\r\n';
  const chunks = composeChunksWithOrigins({ text });
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].startOffset, 3);
  assert.equal(chunks[0].body, 'A 😀 B C');
  assertOrigins(text, chunks);
});

test('overlapping origins stay correct when an end cursor cannot locate the next chunk', () => {
  const text = 'one two three four five six seven eight nine ten eleven twelve';
  const chunks = composeChunksWithOrigins({ text, maxTokens: 6, overlapTokens: 2, strategy: 'light' });
  assert.ok(chunks.length > 2);
  assert.ok(chunks.some((chunk, index) => index > 0 && chunk.startOffset < chunks[index - 1].endOffset));
  assert.ok(chunks.some((chunk, index) => index > 0 && text.indexOf(chunk.body, chunks[index - 1].endOffset) === -1));
  assertOrigins(text, chunks);
});

test('repeated paragraphs keep their actual distinct origins', () => {
  const text = '  Repeat this phrase.\n\nRepeat this phrase.\n\nRepeat this phrase.';
  const chunks = composeChunksWithOrigins({ text, maxTokens: 5, overlapTokens: 0, strategy: 'legacy' });
  assert.deepEqual(chunks.map((chunk) => chunk.body), Array(3).fill('Repeat this phrase.'));
  assert.deepEqual(chunks.map((chunk) => chunk.startOffset), [2, 23, 44]);
  assertOrigins(text, chunks);
});

test('zero overlap does not acquire a minimum overlap window', () => {
  const text = 'alpha beta gamma delta epsilon zeta eta theta';
  const chunks = composeChunksWithOrigins({ text, maxTokens: 4, overlapTokens: 0 });
  for (let index = 1; index < chunks.length; index += 1) assert.ok(chunks[index].startOffset >= chunks[index - 1].endOffset);
  assertOrigins(text, chunks);
});

test('astral Unicode remains intact at forced split and overlap boundaries', () => {
  const text = 'a😀😀😀😀😀😀😀😀😀😀z';
  for (const overlapTokens of [0, 1, 2, 50]) {
    const chunks = composeChunksWithOrigins({ text, maxTokens: 2, overlapTokens });
    assert.ok(chunks.length < text.length);
    assert.equal(chunks.at(-1).endOffset, text.length);
    assertOrigins(text, chunks);
  }
});

test('oversized sentences are forcibly sliced and oversized overlap terminates deterministically', () => {
  const text = 'abcdefghijklmnopqrstuvwx'.repeat(8) + '.';
  for (const overlapTokens of [0, 2, 4, 999]) {
    const args = { text, maxTokens: 4, overlapTokens, strategy: 'hybrid' };
    const chunks = composeChunksWithOrigins(args);
    assert.ok(chunks.length <= text.length);
    assert.ok(chunks.every((chunk) => chunk.body.length <= 16));
    assert.equal(chunks.at(-1).endOffset, text.length);
    assert.deepEqual(chunks, composeChunksWithOrigins(args));
    assertOrigins(text, chunks);
  }
});

test('semantic sentence ranges preserve punctuation and do not search for repeated content', () => {
  const text = ' Hi. Hi. Hi. Hi. Hi. Hi. !!! ';
  const metadata = { lineage: ['attachment:1'], source: 'file' };
  const chunks = composeChunksWithOrigins({ text, maxTokens: 5, overlapTokens: 1, metadata });
  assert.ok(chunks.length > 1);
  assertOrigins(text, chunks);
  assert.equal(chunks.at(-1).body.endsWith('!!!'), true);
  assert.deepEqual(metadata.lineage, ['attachment:1']);
  assert.ok(chunks.every((chunk) => chunk.metadata.lineage[0] === 'attachment:1'));
});

test('hybrid sentence overlap retains source ranges inside one structural window', () => {
  const text = 'A.  B. C. D. E. F. G. H. I. J.';
  const chunks = composeChunksWithOrigins({ text, maxTokens: 4, overlapTokens: 1 });
  assertOrigins(text, chunks);
  const siblings = chunks.filter((chunk) => chunk.metadata.lineage.includes('structural:0'));
  assert.equal(siblings.length, 2);
  assert.equal(siblings[0].body, 'A. B. C. D.');
  assert.equal(siblings[1].body, 'D. E.');
  assert.ok(siblings[1].startOffset < siblings[0].endOffset);
});

test('empty input and invalid budgets have explicit outcomes', () => {
  for (const text of ['', '  \n\t\r ']) assert.deepEqual(composeChunksWithOrigins({ text }), []);
  for (const maxTokens of [0, -1, Infinity, NaN, 1.5]) assert.throws(() => composeChunksWithOrigins({ text: 'x', maxTokens }), RangeError);
  for (const overlapTokens of [-1, Infinity, 1.5]) assert.throws(() => composeChunksWithOrigins({ text: 'x', overlapTokens }), RangeError);
  assert.throws(() => composeChunksWithOrigins({ text: 'x', strategy: 'unknown' }), TypeError);
  assert.throws(() => composeChunksWithOrigins({ text: null }), TypeError);
  assert.throws(() => composeChunksWithOrigins({ text: '\ud800' }), TypeError);
});
