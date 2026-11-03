import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { stage, projectRoot, webFiles } from './stage.mjs';
import { makePdf, normalizeText } from './fixtures.mjs';

const output = resolve(process.argv[2] ?? join(projectRoot, 'benchmark/eval/outputs/wasm-browser'));
await mkdir(output, { recursive: true });
const staged = await stage(join(output, 'deploy'));
const fixturePath = join(projectRoot, 'benchmark/eval/corpus/clean_born_digital/clean-native.pdf');
const scanPath = join(projectRoot, 'benchmark/eval/corpus/scanned_typewritten/image-only-page.pdf');
const truth = normalizeText(await readFile(join(projectRoot, 'benchmark/eval/ground_truth/page_text/clean_born_digital/clean-native.txt'), 'utf8'));
const slowPdf = makePdf({ pages: 60, lines: 100 });
const cancelPath = join(output, 'cancel.pdf');
const invalidPath = join(output, 'invalid.pdf');
await writeFile(cancelPath, makePdf({ pages: 300, lines: 100 }));
await writeFile(invalidPath, new Uint8Array([1, 2, 3]));
const checks = [];
const types = { html: 'text/html', mjs: 'text/javascript', wasm: 'application/wasm', pdf: 'application/pdf' };
const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    if (url.pathname === '/fixture/slow.pdf' || url.pathname === '/fixture/clean.pdf') {
      const body = url.pathname.endsWith('slow.pdf') ? slowPdf : await readFile(fixturePath);
      response.writeHead(200, { 'Content-Type': 'application/pdf', 'Cache-Control': 'no-store' });
      response.end(body);
      return;
    }
    const match = /^\/(nested|slow|missing)\/parser\/([^/]+)$/.exec(url.pathname);
    const name = match?.[2];
    if (!match || ![...webFiles, 'pdf_parser.wasm', 'asset-manifest.json'].includes(name) || (match[1] === 'missing' && name === 'pdf_parser.wasm')) {
      response.writeHead(404, { 'Content-Type': 'text/plain' });
      response.end('missing test asset');
      return;
    }
    if (match[1] === 'slow' && name === 'pdf_parser.wasm') await new Promise(resolve => setTimeout(resolve, 1000));
    const body = await readFile(join(staged.directory, name));
    response.writeHead(200, { 'Content-Type': types[name.split('.').at(-1)] ?? 'application/json', 'Cache-Control': 'no-store' });
    response.end(body);
  } catch (error) { response.writeHead(500); response.end(error.message); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;

function chromeExecutable() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;
  for (const path of ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/Applications/Chromium.app/Contents/MacOS/Chromium']) {
    if (existsSync(path)) return path;
  }
  for (const name of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    const probe = spawnSync('which', [name], { encoding: 'utf8' });
    if (probe.status === 0 && probe.stdout.trim()) return probe.stdout.trim();
  }
  throw new Error('No installed Chrome/Chromium. Set CHROME_BIN; this runner never installs a browser.');
}

class CDP {
  constructor(socket) {
    this.socket = socket;
    this.next = 0;
    this.pending = new Map();
    socket.addEventListener('message', event => {
      const message = JSON.parse(String(event.data));
      if (!message.id) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
      else pending.resolve(message.result);
    });
    socket.addEventListener('close', () => {
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('Chrome CDP connection closed')); }
      this.pending.clear();
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.next;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 60000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
}

let chrome, cdp, profile;
let chromeLog = '';
try {
  profile = await mkdtemp(join(tmpdir(), 'pdf-parser-wasm-browser-'));
  const executable = chromeExecutable();
  const endpoint = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Chrome did not expose DevTools within 30 seconds')), 30000);
    chrome = spawn(executable, ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: ['ignore', 'pipe', 'pipe'] });
    chrome.on('error', error => { clearTimeout(timer); reject(error); });
    chrome.once('exit', code => { clearTimeout(timer); reject(new Error(`Chrome exited before verification: ${code}`)); });
    const collect = chunk => {
      chromeLog += chunk.toString();
      const match = /DevTools listening on (ws:\/\/[^\s]+)/.exec(chromeLog);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    };
    chrome.stdout.on('data', collect);
    chrome.stderr.on('data', collect);
  });
  const socket = new WebSocket(await endpoint);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  cdp = new CDP(socket);
  const version = await cdp.send('Browser.getVersion');
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const send = (method, params) => cdp.send(method, params, sessionId);
  await send('Page.enable');
  await send('Runtime.enable');
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const wait = async (expression, label, timeout = 30000) => {
    const until = Date.now() + timeout;
    while (Date.now() < until) {
      if (await evaluate(expression)) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error(`Timed out waiting for ${label}`);
  };
  const upload = async file => {
    const { root } = await send('DOM.getDocument');
    const { nodeId } = await send('DOM.querySelector', { nodeId: root.nodeId, selector: '#fileInput' });
    assert.ok(nodeId, 'actual file input must exist');
    await send('DOM.setFileInputFiles', { nodeId, files: [file] });
  };
  const check = (name, observation) => checks.push({ name, observation, passed: true });

  await send('Page.navigate', { url: `${origin}/slow/parser/index.html` });
  await wait("Boolean(document.getElementById('fileInput'))", 'initial demo input');
  assert.equal(await evaluate("document.getElementById('fileInput').disabled"), true);
  await wait("document.getElementById('fileInput') && !document.getElementById('fileInput').disabled", 'WASM readiness');
  check('demo keeps input disabled until delayed real Worker/WASM initialization completes', 'controlled one-second binary response delay');

  await upload(fixturePath);
  await wait(`document.getElementById('output').textContent.replace(/\\s+/g,' ').trim() === ${JSON.stringify(truth)}`, 'actual file-input extraction');
  assert.equal(await evaluate("document.getElementById('pageCount').textContent"), '1');
  assert.equal(await evaluate("document.getElementById('outputContainer').classList.contains('hidden')"), false);
  check('actual nested-path demo file input produces checked-in full text truth', '1 page, normalized exact text equality');
  const image = await send('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(output, 'demo.png'), Buffer.from(image.data, 'base64'));

  await wait("!document.getElementById('fileInput').disabled", 'input after completion');
  await upload(scanPath);
  await wait("document.getElementById('output').textContent === '(No text extracted)'", 'successful image-only empty output');
  check('image-only successful extraction stays a success', 'empty string represented by demo empty-output text');

  await wait("!document.getElementById('fileInput').disabled", 'input after empty scan');
  await upload(invalidPath);
  await wait("document.getElementById('error').textContent.includes('Could not open this PDF')", 'readable malformed-PDF error');
  check('actual file input reports malformed PDF without presenting empty success', await evaluate("document.getElementById('error').textContent"));

  await wait("!document.getElementById('fileInput').disabled", 'input after malformed PDF');
  await upload(cancelPath);
  const cancelActive = await evaluate("(() => { const active = document.getElementById('loading').classList.contains('active'); document.getElementById('cancelBtn').click(); return active; })()");
  assert.equal(cancelActive, true, 'Cancel must be exercised during an active UI operation');
  await wait("/cancelled/i.test(document.getElementById('error').textContent) && !document.getElementById('fileInput').disabled", 'actual Cancel button settlement');
  await upload(fixturePath);
  await wait(`document.getElementById('output').textContent.replace(/\\s+/g,' ').trim() === ${JSON.stringify(truth)}`, 'file-input recovery after Cancel');
  check('actual Cancel button settles the operation and permits another upload', 'cancelled message followed by exact clean fixture output');

  const worker = await evaluate(`(async () => {
    const { PDFParserWorker } = await import('./pdf-parser-worker.mjs');
    const clean = await (await fetch('/fixture/clean.pdf')).arrayBuffer();
    const slow = await (await fetch('/fixture/slow.pdf')).arrayBuffer();
    const client = new PDFParserWorker();
    await client.init();
    let beats = 0;
    const heartbeat = setInterval(() => beats++, 1);
    try {
      const result = await client.extract(slow);
      if (result.pageCount !== 60 || !result.text.includes('Independent WASM fixture')) throw new Error('large worker result mismatch');
      if (beats < 1) throw new Error('main-thread heartbeat did not run during worker extraction');
      const retained = clean.byteLength;
      const pending = client.extract(slow);
      const busy = await client.extract(clean).then(() => false, () => true);
      if (!busy) throw new Error('second active job was admitted');
      const cancellation = setTimeout(() => client.cancel(), 10);
      const cancelled = await pending.then(() => false, error => /cancel|abort/i.test(error.name + ' ' + error.message));
      clearTimeout(cancellation);
      if (!cancelled) throw new Error('in-flight worker job did not reject cancellation');
      const recovered = await client.extract(clean);
      if (recovered.pageCount !== 1 || !recovered.text.includes('Clean born digital')) throw new Error('worker did not recover after cancellation');
      if (clean.byteLength !== retained) throw new Error('input transfer detached caller buffer');
      return { beats, pages: result.pageCount, busyRejected: busy, cancelled, recovered: true, callerInputRetained: true };
    } finally {clearInterval(heartbeat); client.dispose();}
  })()`);
  check('real Worker keeps UI responsive, bounds active work, cancels and recovers', worker);

  const negative = await evaluate(`(async () => {
    const { PDFParserWorker } = await import('./pdf-parser-worker.mjs');
    const client = new PDFParserWorker({ wasmUrl: new URL('/missing/parser/pdf_parser.wasm', location.href) });
    try { await client.init(); throw new Error('missing asset unexpectedly initialized'); }
    catch (error) { if (!/404/.test(error.message)) throw error; return { message: error.message }; }
    finally {client.dispose();}
  })()`);
  check('Worker initialization retains missing-asset HTTP identity', negative);

  await send('Page.navigate', { url: `${origin}/missing/parser/index.html` });
  await wait("document.getElementById('error') && /404/.test(document.getElementById('error').textContent)", 'missing binary shown by actual demo');
  assert.equal(await evaluate("document.getElementById('fileInput').disabled"), true);
  check('demo missing binary exposes HTTP404 and input remains disabled', await evaluate("document.getElementById('error').textContent"));

  assert.throws(() => assert.equal('wrong text', truth), assert.AssertionError);
  check('semantic oracle rejects an intentionally incorrect expectation', 'AssertionError observed by negative control');
  const report = { node: process.version, browser: version, artifact: staged.files, checks, limits: 'Local staged static delivery in installed Chrome; not deployed GitHub Pages, other browsers, performance or whole-process memory qualification.' };
  await writeFile(join(output, 'results.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  await writeFile(join(output, 'failure.json'), JSON.stringify({ error: error.stack, checks }, null, 2) + '\n');
  throw error;
} finally {
  cdp?.socket.close();
  if (chrome && chrome.exitCode === null) {
    chrome.kill('SIGTERM');
    await Promise.race([new Promise(resolve => chrome.once('exit', resolve)), new Promise(resolve => setTimeout(resolve, 2000))]);
    if (chrome.exitCode === null) { chrome.kill('SIGKILL'); await new Promise(resolve => chrome.once('exit', resolve)); }
  }
  await new Promise(resolve => server.close(resolve));
  await writeFile(join(output, 'chrome.log'), chromeLog);
  if (profile) await rm(profile, { recursive: true, force: true });
}
