import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { PDFParser } from '../../../web/pdf-parser.mjs';
import { makePdf, normalizeText } from './fixtures.mjs';

const root = new URL('../../../', import.meta.url);
const wasmBytes = await readFile(new URL('zig-out/bin/pdf_parser.wasm', root));
const clean = await readFile(new URL('benchmark/eval/corpus/clean_born_digital/clean-native.pdf', root));
const scan = await readFile(new URL('benchmark/eval/corpus/scanned_typewritten/image-only-page.pdf', root));
const truth = await readFile(new URL('benchmark/eval/ground_truth/page_text/clean_born_digital/clean-native.txt', root), 'utf8');
async function parser(options = {}) {
  const p = new PDFParser({ wasmBytes, ...options });
  await p.init();
  return p;
}
function raw(p, input = clean, decodedLimit = 32 * 1024 * 1024) {
  const ptr = p.alloc(input.length);
  new Uint8Array(p.memory.buffer, ptr, input.length).set(input);
  const out = p.alloc(12);
  const status = p.wasm.pdf_parser_wasm_open(ptr, input.length, decodedLimit, out);
  const handle = new Uint32Array(p.memory.buffer, out, 1)[0];
  return {
    p, ptr, out, status, handle,
    fields: () => new Uint32Array(p.memory.buffer, out, 3),
    close() { if (status === 0) p.wasm.pdf_parser_wasm_close(handle); p.free(out, 12); p.free(ptr, input.length); },
  };
}

test('final core artifact validates, has no host imports, exposes v2 and legacy APIs', async () => {
  assert.equal(WebAssembly.validate(wasmBytes), true);
  const module = await WebAssembly.compile(wasmBytes);
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const p = await parser();
  assert.equal(p.wasm.pdf_parser_wasm_abi_version(), 2);
  for (const name of ['zpdf_open_memory', 'zpdf_open_memory_unsafe', 'zpdf_close', 'zpdf_page_count', 'zpdf_extract_page', 'zpdf_extract_all', 'zpdf_extract_bounds', 'zpdf_free_bounds']) {
    assert.equal(typeof p.wasm[name], 'function', name);
  }
});

test('final binary declares a finite guest-memory maximum and refuses growth beyond it', async () => {
  let offset = 8, maximum;
  const readU32 = () => {
    let value = 0, shift = 0, byte;
    do { byte = wasmBytes[offset++]; value += (byte & 127) * 2 ** shift; shift += 7; } while (byte & 128);
    return value;
  };
  while (offset < wasmBytes.length) {
    const section = wasmBytes[offset++], length = readU32(), end = offset + length;
    if (section === 5) {
      assert.equal(readU32(), 1, 'one guest memory');
      const flags = readU32();
      readU32(); // Initial pages are allowed to evolve as static data grows.
      assert.equal(flags & 1, 1, 'declared maximum is required');
      assert.equal(flags & 2, 0, 'baseline build does not require shared memory');
      maximum = readU32();
    }
    offset = end;
  }
  assert.ok(Number.isSafeInteger(maximum) && maximum > 0);
  const p = await parser();
  // Adding the maximum to a nonempty memory necessarily exceeds its ceiling;
  // the engine must reject before allocating that many bytes.
  assert.throws(() => p.memory.grow(maximum), RangeError);
});

test('actual wrapper returns checked-in text truth and owned strings across growth/close', async () => {
  const p = await parser();
  const doc = p.openPDF(clean);
  const text = p.extractAll(doc);
  assert.equal(p.getPageCount(doc), 1);
  assert.equal(normalizeText(text), normalizeText(truth));
  const before = p.memory.buffer;
  p.memory.grow(1);
  assert.equal(before.byteLength, 0);
  assert.equal(p.extractAll(doc), text);
  p.closePDF(doc);
  assert.equal(normalizeText(text), normalizeText(truth));
});

test('empty successful scan is distinct from an invalid page or closed document', async () => {
  const p = await parser();
  const doc = p.openPDF(scan);
  assert.equal(p.extractAll(doc), '');
  assert.throws(() => p.extractPage(doc, -1));
  assert.throws(() => p.extractPage(doc, 1));
  p.closePDF(doc);
  p.closePDF(doc);
  assert.throws(() => p.extractAll(doc));
});

test('document wrappers reject another parser owner and preserve replacement document', async () => {
  const a = await parser(), b = await parser();
  const doc = a.openPDF(clean);
  try { assert.throws(() => b.getPageCount(doc)); assert.throws(() => b.closePDF(doc)); }
  finally { a.closePDF(doc); }
  const next = a.openPDF(clean);
  try { a.closePDF(doc); assert.equal(a.getPageCount(next), 1); }
  finally { a.closePDF(next); }
});

test('v2 stale numeric handle cannot read or close a replacement document', async () => {
  const p = await parser(), old = raw(p);
  assert.equal(old.status, 0);
  assert.equal(p.wasm.pdf_parser_wasm_close(old.handle), 0);
  const next = raw(p);
  try {
    assert.equal(next.status, 0);
    assert.notEqual(next.handle, old.handle);
    next.fields()[0] = 12345;
    assert.equal(p.wasm.pdf_parser_wasm_page_count(old.handle, next.out), 2);
    assert.equal(next.fields()[0], 0);
    assert.equal(p.wasm.pdf_parser_wasm_close(old.handle), 2);
    assert.equal(p.wasm.pdf_parser_wasm_page_count(next.handle, next.out), 0);
    assert.equal(next.fields()[0], 1);
    // Legacy numeric slots cannot accidentally destroy a v2 document.
    p.wasm.zpdf_close(next.handle);
    assert.equal(p.wasm.pdf_parser_wasm_page_count(next.handle, next.out), 0);
  } finally { next.close(); old.close(); }
});

test('raw failures clear results; bounded output refuses before success and can retry', async () => {
  const p = await parser(), d = raw(p);
  try {
    assert.equal(d.status, 0);
    d.fields().set([123, 456, 789]);
    assert.equal(p.wasm.pdf_parser_wasm_extract_page(d.handle, -1, 1024, d.out, d.out + 4), 3);
    assert.deepEqual(Array.from(d.fields().slice(0, 2)), [0, 0]);
    d.fields().set([123, 456, 789]);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(d.handle, 1, d.out, d.out + 4), 7);
    assert.deepEqual(Array.from(d.fields().slice(0, 2)), [0, 0]);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(d.handle, 1024 * 1024, d.out, d.out + 4), 0);
    const [ptr, length] = d.fields();
    try { assert.equal(normalizeText(p.readString(ptr, length)), normalizeText(truth)); }
    finally { p.free(ptr, length); }
    d.fields().set([123, 456, 789]);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(d.handle, 1024, d.out, d.out), 1);
  } finally { d.close(); }
});

test('raw empty result is a successful null pointer plus zero length', async () => {
  const p = await parser(), d = raw(p, scan);
  try {
    assert.equal(d.status, 0);
    d.fields().set([123, 456, 789]);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(d.handle, 1024, d.out, d.out + 4), 0);
    assert.deepEqual(Array.from(d.fields().slice(0, 2)), [0, 0]);
  } finally { d.close(); }
});

test('raw v2 rejects invalid ranges and scalar alignment without trapping', async () => {
  const p = await parser(), d = raw(p);
  try {
    assert.equal(d.status, 0);
    assert.equal(p.wasm.pdf_parser_wasm_page_count(d.handle, 0), 1);
    assert.equal(p.wasm.pdf_parser_wasm_page_count(d.handle, d.out + 1), 1);
    assert.equal(p.wasm.pdf_parser_wasm_open(0xffffffff, 64, 1024, d.out), 1);
    assert.equal(d.fields()[0], 0);
    assert.equal(p.wasm.pdf_parser_wasm_open(d.ptr, clean.length, 0, d.out), 1);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(d.handle, 1024, d.out, 0xffffffff), 1);
    assert.equal(d.fields()[0], 0);
    d.fields().set([123, 456, 789]);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(0, 1024, d.out, d.out + 4), 2);
    assert.deepEqual(Array.from(d.fields().slice(0, 2)), [0, 0]);
    const before = Uint8Array.from(new Uint8Array(p.memory.buffer, d.ptr, clean.length));
    assert.equal(p.wasm.pdf_parser_wasm_open(d.ptr, clean.length, 1024, d.ptr + 4), 1);
    assert.deepEqual(new Uint8Array(p.memory.buffer, d.ptr, clean.length), before);
  } finally { d.close(); }
});

test('legacy document operations remain callable with their original slot semantics', async () => {
  const p = await parser(), ptr = p.alloc(clean.length), out = p.alloc(4);
  new Uint8Array(p.memory.buffer, ptr, clean.length).set(clean);
  const handle = p.wasm.zpdf_open_memory(ptr, clean.length);
  try {
    assert.ok(handle >= 0 && handle < 16);
    assert.equal(p.wasm.zpdf_page_count(handle), 1);
    const textPtr = p.wasm.zpdf_extract_all(handle, out);
    const length = new Uint32Array(p.memory.buffer, out, 1)[0];
    try { assert.equal(normalizeText(p.readString(textPtr, length)), normalizeText(truth)); }
    finally { p.free(textPtr, length); }
    new Uint32Array(p.memory.buffer, out, 1)[0] = 12345;
    assert.equal(p.wasm.zpdf_extract_page(-1, 0, out), 0);
    assert.equal(new Uint32Array(p.memory.buffer, out, 1)[0], 0);
  } finally { p.wasm.zpdf_close(handle); p.free(out, 4); p.free(ptr, clean.length); }
});

test('capacity refusal releases input and a closed slot can be reused', async () => {
  const p = await parser(), docs = [];
  try {
    for (let i = 0; i < 16; i++) docs.push(p.openPDF(clean));
    assert.throws(() => p.openPDF(clean));
    p.closePDF(docs.pop());
    docs.push(p.openPDF(clean));
    assert.equal(p.getPageCount(docs.at(-1)), 1);
  } finally { docs.forEach(d => p.closePDF(d)); }
});

test('malformed input and configured input/output limits reject explicitly', async () => {
  const p = await parser();
  assert.throws(() => p.openPDF(new Uint8Array([1, 2, 3])));
  assert.throws(() => p.openPDF(new Uint8Array()));
  const limited = await parser({ maxInputBytes: clean.length - 1 });
  assert.throws(() => limited.openPDF(clean));
  const outputLimited = await parser({ maxOutputBytes: 1 });
  const d = outputLimited.openPDF(clean);
  try { assert.throws(() => outputLimited.extractAll(d)); }
  finally { outputLimited.closePDF(d); }
});

test('compressed-stream refusal survives raw extraction with independent serialized input', async () => {
  const fixture = makePdf({ compressed: true, lines: 5 });
  const p = await parser(), good = raw(p, fixture), small = raw(p, fixture, 32);
  try {
    assert.equal(good.status, 0);
    assert.equal(small.status, 0);
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(good.handle, 1024 * 1024, good.out, good.out + 4), 0);
    const [ptr, length] = good.fields();
    try { assert.match(p.readString(ptr, length), /Independent WASM fixture/); }
    finally { p.free(ptr, length); }
    assert.equal(p.wasm.pdf_parser_wasm_extract_all(small.handle, 1024 * 1024, small.out, small.out + 4), 7);
    assert.deepEqual(Array.from(small.fields().slice(0, 2)), [0, 0]);
  } finally { good.close(); small.close(); }
});

test('Buffer slice offsets and typed-array input preserve original owned bytes', async () => {
  const p = await parser(), backing = Buffer.concat([Buffer.from('prefix'), clean, Buffer.from('suffix')]);
  const input = backing.subarray(6, 6 + clean.length), snapshot = Buffer.from(input);
  const result = p.extractDocument(input);
  assert.equal(normalizeText(result.text), normalizeText(truth));
  assert.deepEqual(input, snapshot);
  assert.equal(backing.byteLength, clean.length + 12);
});

test('host decoding exception releases output and scratch while document stays usable', async () => {
  const p = await parser(), d = p.openPDF(clean), readString = p.readString;
  const guest = p.wasm, free = guest.wasm_free;
  let frees = 0;
  p.wasm = { ...guest, wasm_free(...args) { frees++; return free(...args); } };
  p.readString = () => { throw new Error('injected-host-decode'); };
  try {
    assert.throws(() => p.extractAll(d), /injected-host-decode/);
    assert.equal(frees, 2);
    p.readString = readString;
    assert.equal(normalizeText(p.extractAll(d)), normalizeText(truth));
  } finally { p.readString = readString; p.closePDF(d); }
});

test('document extraction helper closes acquired document on extraction exception', async () => {
  const p = await parser(), extract = p.extractAll, close = p.closePDF;
  let closes = 0;
  p.extractAll = () => { throw new Error('injected-extraction'); };
  p.closePDF = function (doc) { closes++; return close.call(this, doc); };
  assert.throws(() => p.extractDocument(clean), /injected-extraction/);
  assert.equal(closes, 1);
  p.extractAll = extract;
  assert.equal(normalizeText(p.extractDocument(clean).text), normalizeText(truth));
});

test('initialization shares one promise and HTTP failure retains status', async () => {
  let calls = 0, release;
  const response = new Promise(resolve => { release = resolve; });
  const p = new PDFParser({ fetch: () => { calls++; return response; } });
  const first = p.init(), second = p.init();
  assert.equal(first, second);
  assert.throws(() => p.openPDF(clean));
  release(new Response(wasmBytes, { headers: { 'content-type': 'application/wasm' } }));
  await first;
  assert.equal(calls, 1);
  assert.equal(p.extractDocument(clean).pageCount, 1);
  const missing = new PDFParser({ fetch: async () => new Response('missing', { status: 404 }) });
  await assert.rejects(missing.init(), /404/);
});

test('default platform fetch keeps its global receiver when the parser initializes', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  let p;
  try {
    globalThis.fetch = function () {
      assert.equal(this, globalThis, 'browser fetch requires its global receiver');
      calls++;
      return Promise.resolve(new Response(wasmBytes));
    };
    p = new PDFParser();
  } finally { globalThis.fetch = original; }
  await p.init();
  assert.equal(calls, 1);
  assert.equal(p.extractDocument(clean).pageCount, 1);
});

test('semantic oracle throws for intentionally incorrect output', () => {
  assert.throws(() => assert.equal(normalizeText('wrong text'), normalizeText(truth)), assert.AssertionError);
});
