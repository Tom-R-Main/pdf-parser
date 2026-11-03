import { inputBytes, PDFParserError } from './pdf-parser.mjs';

/** One active document per worker; no hidden queue or shared guest heap. */
export class PDFParserWorker {
    constructor({ workerUrl = new URL('worker.mjs', import.meta.url), wasmUrl = new URL('pdf_parser.wasm', import.meta.url),
        maxInputBytes = 32 * 1024 * 1024, maxOutputBytes = 16 * 1024 * 1024,
        maxDecodedStreamBytes = 32 * 1024 * 1024, timeoutMs = 45000,
        workerFactory = url => new Worker(url, { type: 'module' }) } = {}) {
        for (const [name, value] of Object.entries({ maxInputBytes, maxOutputBytes, maxDecodedStreamBytes, timeoutMs })) {
            if (!Number.isSafeInteger(value) || value <= 0 || value > 0x7fffffff) throw new RangeError(`${name} must be a positive integer`);
        }
        this.options = { maxInputBytes, maxOutputBytes, maxDecodedStreamBytes };
        this.wasmUrl = String(wasmUrl);
        this.workerUrl = workerUrl;
        this.timeoutMs = timeoutMs;
        this.workerFactory = workerFactory;
        this._worker = null;
        this._ready = null;
        this._pending = new Map();
        this._nextId = 1;
        this._active = null;
        this._disposed = false;
    }

    _reset(error) {
        if (this._active) this._active.error = error;
        const worker = this._worker;
        this._worker = null;
        this._ready = null;
        worker?.terminate();
        for (const entry of this._pending.values()) {
            clearTimeout(entry.timer);
            entry.reject(error);
        }
        this._pending.clear();
    }

    _request(type, payload = {}, transfers = []) {
        const id = this._nextId++;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => this._reset(new PDFParserError('Parser worker timed out', 'timeout')), this.timeoutMs);
            this._pending.set(id, { resolve, reject, timer });
            try { this._worker.postMessage({ id, type, ...payload }, transfers); }
            catch (error) { this._reset(error); }
        });
    }

    init() {
        if (this._disposed) return Promise.reject(new PDFParserError('Parser worker is disposed', 'disposed'));
        if (!this._ready) {
            const worker = this.workerFactory(this.workerUrl);
            this._worker = worker;
            worker.onmessage = ({ data }) => {
                if (this._worker !== worker) return;
                const entry = this._pending.get(data?.id);
                if (!entry) return;
                if (data.type !== 'RESULT' && data.type !== 'ERROR') {
                    this._reset(new PDFParserError('Invalid parser worker response', 'protocol_error'));
                    return;
                }
                this._pending.delete(data.id);
                clearTimeout(entry.timer);
                if (data.type === 'RESULT') entry.resolve(data.result);
                else {
                    const error = new PDFParserError(data.error?.message ?? 'Parser worker failed', data.error?.code ?? 'worker_error', data.error?.status);
                    if (data.error?.name) error.name = data.error.name;
                    entry.reject(error);
                    if (data.fatal) this._reset(error);
                }
            };
            worker.onerror = event => {
                if (this._worker !== worker) return;
                event.preventDefault?.();
                this._reset(new PDFParserError(event.message || 'Parser worker failed', 'worker_error'));
            };
            worker.onmessageerror = () => {
                if (this._worker === worker) this._reset(new PDFParserError('Parser worker message could not be decoded', 'protocol_error'));
            };
            // Defer request dispatch until _ready is assigned, including synchronous mock failures.
            const ready = Promise.resolve().then(() => {
                if (this._worker !== worker) throw new DOMException('PDF extraction cancelled', 'AbortError');
                return this._request('INIT', { wasmUrl: this.wasmUrl, options: this.options });
            });
            this._ready = ready;
            ready.catch(error => { if (this._ready === ready) this._reset(error); });
        }
        return this._ready;
    }

    async extract(data, { signal } = {}) {
        if (this._active) throw new PDFParserError('Parser is busy; wait for the current document', 'busy');
        if (signal?.aborted) throw new DOMException('PDF extraction cancelled', 'AbortError');
        const bytes = inputBytes(data);
        if (bytes.byteLength === 0) throw new PDFParserError('PDF input is empty', 'invalid_argument', 1);
        if (bytes.byteLength > this.options.maxInputBytes) throw new PDFParserError('PDF input exceeds maxInputBytes', 'resource_limit', 7);
        const owned = Uint8Array.from(bytes);
        const active = {};
        this._active = active;
        const abort = () => this.cancel();
        signal?.addEventListener('abort', abort, { once: true });
        try {
            await this.init();
            if (active.error) throw active.error;
            if (signal?.aborted) throw new DOMException('PDF extraction cancelled', 'AbortError');
            // Copy independently before transferring: callers retain their original storage.
            return await this._request('EXTRACT', { bytes: owned }, [owned.buffer]);
        } finally {
            signal?.removeEventListener('abort', abort);
            if (this._active === active) this._active = null;
        }
    }

    cancel() { this._reset(new DOMException('PDF extraction cancelled', 'AbortError')); }

    dispose() {
        this._disposed = true;
        this._reset(new PDFParserError('Parser worker is disposed', 'disposed'));
    }
}
