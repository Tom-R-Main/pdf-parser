import { createHash } from 'node:crypto';

const WHITESPACE = /\s/u;

function safeBoundary(text, offset, direction) {
  if (offset > 0 && offset < text.length &&
      /[\uD800-\uDBFF]/u.test(text[offset - 1]) && /[\uDC00-\uDFFF]/u.test(text[offset])) {
    return offset + direction;
  }
  return offset;
}

function trimRange(text, start, end) {
  while (start < end && WHITESPACE.test(text[start])) start += 1;
  while (end > start && WHITESPACE.test(text[end - 1])) end -= 1;
  return { start, end };
}

// Runs keep normalization reversible without allocating one map entry per character.
function normalizeRange(text, start, end) {
  const pieces = [];
  const runs = [];
  let length = 0;
  const pattern = /\s+|\S+/gu;
  const input = text.slice(start, end);
  for (const match of input.matchAll(pattern)) {
    const sourceStart = start + match.index;
    const sourceEnd = sourceStart + match[0].length;
    const whitespace = WHITESPACE.test(match[0][0]);
    const body = whitespace ? ' ' : match[0];
    pieces.push(body);
    runs.push({ start: length, end: length + body.length, sourceStart, sourceEnd, whitespace });
    length += body.length;
  }
  return { body: pieces.join(''), runs };
}

function sourceBoundary(runs, offset, isEnd) {
  let low = 0;
  let high = runs.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    const beforeBoundary = isEnd ? runs[middle].end < offset : runs[middle].end <= offset;
    if (beforeBoundary) low = middle + 1;
    else high = middle;
  }
  const run = runs[low];
  if (!run) return runs.at(-1).sourceEnd;
  if (run.whitespace) return isEnd ? run.sourceEnd : run.sourceStart;
  return run.sourceStart + offset - run.start;
}

function structuralRanges(text, start, end, maxChars, overlapChars) {
  const ranges = [];
  while (start < end) {
    let stop = safeBoundary(text, Math.min(start + maxChars, end), -1);
    if (stop < end) {
      const threshold = start + overlapChars;
      const paragraph = text.lastIndexOf('\n\n', stop);
      const sentence = text.lastIndexOf('. ', stop - 1);
      const word = text.lastIndexOf(' ', stop);
      if (paragraph > threshold && paragraph <= stop) stop = paragraph;
      else if (sentence > threshold) stop = sentence + 1;
      else if (word > threshold) stop = word;
    }
    const trimmed = trimRange(text, start, stop);
    if (trimmed.start < trimmed.end) ranges.push(trimmed);
    if (stop === end) break;
    start = safeBoundary(text, Math.max(stop - overlapChars, start + 1), 1);
    while (start < end && WHITESPACE.test(text[start])) start += 1;
  }
  return ranges;
}

function semanticRanges(body, maxTokens, overlapTokens) {
  const sentences = [];
  let start = 0;
  for (const match of body.matchAll(/[.!?]+(?=\s|$)/gu)) {
    const end = match.index + match[0].length;
    const range = trimRange(body, start, end);
    if (range.start < range.end) sentences.push(range);
    start = end;
  }
  const last = trimRange(body, start, body.length);
  if (last.start < last.end) sentences.push(last);
  const estimate = ({ start, end }) => Math.ceil((end - start) / 4);
  const ranges = [];
  let first = 0;
  while (first < sentences.length) {
    let next = first;
    let tokens = 0;
    while (next < sentences.length && (next === first || tokens + estimate(sentences[next]) <= maxTokens)) {
      tokens += estimate(sentences[next]);
      next += 1;
    }
    ranges.push({ start: sentences[first].start, end: sentences[next - 1].end });
    if (next === sentences.length) break;
    let retained = 0;
    let newFirst = next;
    while (overlapTokens > 0 && newFirst > first + 1 && retained < overlapTokens) {
      newFirst -= 1;
      retained += estimate(sentences[newFirst]);
    }
    first = newFirst;
  }
  return ranges;
}

/**
 * Compose chunks while retaining original UTF-16 ranges through every transform.
 * Budgets use an explicit four UTF-16 units/token approximation, not a tokenizer.
 * Structural overlap is clamped below the window size to guarantee advancement.
 * The exact untrimmed input is the source of offsets and the SHA-256 (UTF-8 encoded).
 */
export function composeChunksWithOrigins({
  text,
  strategy = 'hybrid',
  maxTokens = 256,
  overlapTokens = 32,
  metadata = {},
}) {
  if (typeof text !== 'string') throw new TypeError('text must be a string');
  if (!text.isWellFormed()) throw new TypeError('text must contain well-formed Unicode');
  if (!['legacy', 'hybrid', 'light'].includes(strategy)) throw new TypeError('unsupported chunk strategy');
  if (!Number.isSafeInteger(maxTokens) || maxTokens < 1 || maxTokens > Math.floor(Number.MAX_SAFE_INTEGER / 4)) {
    throw new RangeError('maxTokens must be a positive safe integer within the character budget');
  }
  if (!Number.isSafeInteger(overlapTokens) || overlapTokens < 0) throw new RangeError('overlapTokens must be a nonnegative safe integer');
  if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) throw new TypeError('metadata must be an object');
  if (metadata.lineage !== undefined && (!Array.isArray(metadata.lineage) || !metadata.lineage.every((entry) => typeof entry === 'string'))) {
    throw new TypeError('metadata.lineage must be an array of strings');
  }
  const inputRange = trimRange(text, 0, text.length);
  if (inputRange.start === inputRange.end) return [];
  const sourceTextSha256 = createHash('sha256').update(text, 'utf8').digest('hex');
  const maxChars = maxTokens * 4;
  const overlapChars = Math.min(overlapTokens, maxTokens) * 4;
  const structural = structuralRanges(text, inputRange.start, inputRange.end, maxChars, Math.min(overlapChars, maxChars - 1));
  const result = [];
  structural.forEach((range, structuralIndex) => {
    const view = normalizeRange(text, range.start, range.end);
    const segments = strategy === 'hybrid'
      ? semanticRanges(view.body, maxTokens, overlapTokens)
      : [{ start: 0, end: view.body.length }];
    segments.forEach((segment, segmentIndex) => {
      const index = result.length;
      result.push({
        index,
        body: view.body.slice(segment.start, segment.end),
        startOffset: sourceBoundary(view.runs, segment.start, false),
        endOffset: sourceBoundary(view.runs, segment.end, true),
        offsetUnit: 'utf16_code_unit',
        sourceTextSha256,
        normalization: 'collapse_whitespace_trim',
        metadata: { ...metadata, lineage: [...(metadata.lineage ?? []), `structural:${structuralIndex}`, `segment:${segmentIndex}`, `chunk:${index}`] },
      });
    });
  });
  return result;
}
