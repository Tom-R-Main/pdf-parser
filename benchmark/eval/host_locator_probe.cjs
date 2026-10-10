#!/usr/bin/env node
/** Research reduction of the host's actual normalization/offset functions.
 * Loads only those functions; never imports host configuration, DB, or providers.
 * Requires the host's already-installed TypeScript compiler API.
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { createRequire } = require('node:module');

const [hostRoot, chunkingPath, indexingPath] = process.argv.slice(2);
if (!hostRoot || !chunkingPath || !indexingPath) {
  throw new Error('Usage: node host_locator_probe.cjs CONSUMER_ROOT CHUNKING_SOURCE INDEXING_SOURCE');
}
const hostRequire = createRequire(path.join(hostRoot, 'package.json'));
const ts = hostRequire('typescript');
const sources = {
  chunking: chunkingPath,
  indexing: indexingPath,
};
const contents = Object.fromEntries(Object.entries(sources).map(([key, relative]) =>
  [key, fs.readFileSync(path.join(hostRoot, relative), 'utf8')]));

function extractFunction(source, first, next) {
  const start = source.indexOf(`function ${first}(`);
  const end = source.indexOf(`function ${next}(`, start);
  if (start < 0 || end < 0) throw new Error(`Source changed: ${first} boundaries missing`);
  return source.slice(start, end);
}

const selected = extractFunction(contents.chunking, 'normaliseWhitespace', 'splitSentences')
  + '\n' + extractFunction(contents.indexing, 'findOffset', 'metadataString');
const compiled = ts.transpileModule(selected, {
  compilerOptions: { target: ts.ScriptTarget.ES2022 },
}).outputText;
const context = vm.createContext({});
vm.runInContext(compiled, context, { timeout: 1000 });

const cases = ['A B C', 'A   B C', 'The office\n\napproved the budget.', 'A 😀  B'];
const results = cases.map((raw) => {
  const chunk = context.normaliseWhitespace(raw);
  const offsets = context.findOffset(raw, chunk, 0);
  const rawSlice = raw.slice(offsets.start, offsets.end);
  const normalizedRawSlice = context.normaliseWhitespace(rawSlice);
  return { raw, chunk, offsets, rawSlice, normalizedRawSlice,
    sourceRangeCoversChunk: normalizedRawSlice === chunk };
});
console.log(JSON.stringify({
  evidenceBoundary: 'isolated actual host functions; no DB, UI, or ingestion run',
  hostRoot,
  typescriptVersion: ts.version,
  sources: Object.entries(sources).map(([key, relative]) => ({
    path: path.join(hostRoot, relative),
    sha256: crypto.createHash('sha256').update(contents[key]).digest('hex'),
  })),
  results,
}, null, 2));
