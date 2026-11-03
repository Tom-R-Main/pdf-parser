import { PDFParserWorker } from './pdf-parser-worker.mjs';

const parser = new PDFParserWorker();
const fileInput = document.getElementById('fileInput');
const dropZone = document.getElementById('dropZone');
const cancelButton = document.getElementById('cancelBtn');
let ready = false;
let active = null;

function showError(message) {
    const error = document.getElementById('error');
    error.textContent = message;
    error.classList.remove('hidden');
}

function extractionError(error) {
    if (error.name === 'AbortError') return 'PDF extraction cancelled.';
    const messages = {
        open_error: 'Could not open this PDF. It may be damaged or require a password.',
        extract_error: 'Could not extract text from this PDF.',
        resource_limit: 'This PDF exceeds the browser extraction limits.',
        invalid_handle: 'This document is closed. Please select the PDF again.',
        invalid_page: 'This page is not available.',
    };
    if (error.name === 'RuntimeError') return 'PDF processing stopped unexpectedly. Try another document.';
    return messages[error.code] ?? `Error processing PDF: ${error.message}`;
}

function updateControls() {
    fileInput.disabled = !ready || active !== null;
    dropZone.setAttribute('aria-disabled', String(fileInput.disabled));
    document.getElementById('loading').classList.toggle('active', active !== null);
    cancelButton.classList.toggle('hidden', active === null);
}

async function processFile(file) {
    if (!ready) { showError('Parser is loading. Please wait.'); return; }
    if (active) { showError('Finish or cancel the current document first.'); return; }
    const current = { controller: new AbortController() };
    active = current;
    updateControls();
    document.getElementById('error').classList.add('hidden');
    document.getElementById('stats').classList.add('hidden');
    document.getElementById('outputContainer').classList.add('hidden');
    document.getElementById('warnings').classList.add('hidden');
    try {
        if (file.size > parser.options.maxInputBytes) throw new Error('PDF exceeds the 32 MiB browser input limit');
        const data = await file.arrayBuffer();
        const startTime = performance.now();
        const { pageCount, text, warningCount } = await parser.extract(data, { signal: current.controller.signal });
        const duration = performance.now() - startTime;
        document.getElementById('pageCount').textContent = String(pageCount);
        document.getElementById('charCount').textContent = text.length.toLocaleString();
        document.getElementById('extractTime').textContent = `${duration.toFixed(1)}ms`;
        document.getElementById('speed').textContent = duration > 0 ? `${(pageCount / (duration / 1000)).toFixed(1)} pages/s` : '-';
        document.getElementById('stats').classList.remove('hidden');
        document.getElementById('output').textContent = text || '(No text extracted)';
        document.getElementById('outputContainer').classList.remove('hidden');
        if (warningCount > 0) {
            const warnings = document.getElementById('warnings');
            warnings.textContent = `The parser recorded ${warningCount} diagnostic(s). Review this extraction before relying on it.`;
            warnings.classList.remove('hidden');
        }
    } catch (error) {
        showError(extractionError(error));
    } finally {
        if (active === current) active = null;
        updateControls();
    }
}

updateControls();
parser.init().then(() => {
    ready = true;
    updateControls();
}).catch(error => {
    showError(`Failed to load WASM module: ${error.message}`);
    updateControls();
});

dropZone.addEventListener('click', () => { if (!fileInput.disabled) fileInput.click(); });
dropZone.addEventListener('dragover', event => { event.preventDefault(); dropZone.classList.add('dragover'); });
dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
dropZone.addEventListener('drop', event => {
    event.preventDefault();
    dropZone.classList.remove('dragover');
    const file = event.dataTransfer.files[0];
    if (file && (file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf'))) processFile(file);
    else showError('Please drop a PDF file');
});
fileInput.addEventListener('change', () => {
    const file = fileInput.files[0];
    fileInput.value = '';
    if (file) processFile(file);
});
cancelButton.addEventListener('click', () => active?.controller.abort());
document.getElementById('copyBtn').addEventListener('click', async () => {
    try {
        await navigator.clipboard.writeText(document.getElementById('output').textContent);
        const button = document.getElementById('copyBtn');
        button.textContent = 'Copied!';
        setTimeout(() => { button.textContent = 'Copy to Clipboard'; }, 2000);
    } catch (error) { showError(`Could not copy text: ${error.message}`); }
});
window.addEventListener('pagehide', event => {
    if (event.persisted) parser.cancel();
    else parser.dispose();
});
