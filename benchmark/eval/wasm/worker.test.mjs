import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PDFParserWorker } from '../../../web/pdf-parser-worker.mjs';

// Scheduling controls only. Browser coverage executes the real Worker/module.
class ScheduledWorker {
  constructor() { this.posts = []; this.terminated = false; }
  postMessage(data, transfers = []) {
    this.posts.push(structuredClone(data, { transfer: transfers }));
  }
  terminate() { this.terminated = true; }
  reply(message) { this.onmessage?.({ data: message }); }
  result(index, result) { this.reply({ id: this.posts[index].id, type: 'RESULT', result }); }
}
function harness(options = {}) {
  const workers = [];
  const client = new PDFParserWorker({
    ...options,
    workerFactory: () => { const worker = new ScheduledWorker(); workers.push(worker); return worker; },
  });
  return { client, workers };
}
async function posts(worker, count) {
  for (let i = 0; i < 12 && worker.posts.length < count; i++) await Promise.resolve();
  assert.equal(worker.posts.length, count);
}

test('scheduling control: cancel before INIT dispatch never sends into a replacement Worker', async () => {
  const { client, workers } = harness();
  try {
    const first = client.init();
    client.cancel();
    const second = client.init();
    await assert.rejects(first, /cancel/i);
    await posts(workers[1], 1);
    assert.equal(workers[0].terminated, true);
    assert.equal(workers[0].posts.length, 0);
    assert.equal(workers[1].posts[0].type, 'INIT');
    workers[1].result(0, { abiVersion: 2 });
    await second;
    assert.equal(workers[1].terminated, false);
  } finally { client.dispose(); }
});

test('scheduling control: input is snapshotted before asynchronous initialization', async () => {
  const { client, workers } = harness();
  const input = new Uint8Array([1, 2, 3, 4]);
  try {
    const pending = client.extract(input);
    input.fill(9);
    await posts(workers[0], 1);
    workers[0].result(0, { abiVersion: 2 });
    await posts(workers[0], 2);
    assert.equal(workers[0].posts[1].type, 'EXTRACT');
    assert.deepEqual(Array.from(workers[0].posts[1].bytes), [1, 2, 3, 4]);
    assert.deepEqual(Array.from(input), [9, 9, 9, 9]);
    assert.equal(input.byteLength, 4);
    workers[0].result(1, { pageCount: 1, text: 'owned result', warningCount: 0 });
    assert.equal((await pending).text, 'owned result');
  } finally { client.dispose(); }
});

test('scheduling control: timeout rejects work and the next extraction initializes a new Worker', async () => {
  const { client, workers } = harness({ timeoutMs: 25 });
  try {
    const timedOut = client.extract(new Uint8Array([1]));
    await assert.rejects(timedOut, /timed out/i);
    assert.equal(workers[0].terminated, true);
    const recovered = client.extract(new Uint8Array([2]));
    await posts(workers[1], 1);
    workers[1].result(0, { abiVersion: 2 });
    await posts(workers[1], 2);
    workers[1].result(1, { pageCount: 1, text: 'recovered', warningCount: 0 });
    assert.equal((await recovered).text, 'recovered');
  } finally { client.dispose(); }
});

test('scheduling control: a stale Worker cannot settle a new Worker request', async () => {
  const { client, workers } = harness();
  try {
    const oldReady = client.init();
    await posts(workers[0], 1);
    client.cancel();
    await assert.rejects(oldReady, /cancel/i);
    const newReady = client.init();
    await posts(workers[1], 1);
    let settled = false;
    newReady.then(() => { settled = true; }, () => { settled = true; });
    // Even a matching current id sent by the old event source must be ignored.
    workers[0].reply({ id: workers[1].posts[0].id, type: 'ERROR', fatal: true, error: { message: 'stale response' } });
    await Promise.resolve();
    assert.equal(settled, false);
    assert.equal(workers[1].terminated, false);
    workers[1].result(0, { abiVersion: 2 });
    await newReady;
    assert.equal(settled, true);
  } finally { client.dispose(); }
});

test('scheduling control: dispose rejects pending extraction and permanently refuses new work', async () => {
  const { client, workers } = harness();
  try {
    const ready = client.init();
    await posts(workers[0], 1);
    workers[0].result(0, { abiVersion: 2 });
    await ready;
    const pending = client.extract(new Uint8Array([1]));
    await posts(workers[0], 2);
    client.dispose();
    await assert.rejects(pending, /disposed/i);
    assert.equal(workers[0].terminated, true);
    await assert.rejects(client.init(), /disposed/i);
    await assert.rejects(client.extract(new Uint8Array([2])), /disposed/i);
    assert.equal(workers.length, 1);
  } finally { client.dispose(); }
});

test('scheduling control: pre-aborted extraction creates no Worker or pending work', async () => {
  const { client, workers } = harness();
  const controller = new AbortController();
  controller.abort();
  try {
    await assert.rejects(client.extract(new Uint8Array([1]), { signal: controller.signal }), error => error.name === 'AbortError');
    assert.equal(workers.length, 0);
  } finally { client.dispose(); }
});
