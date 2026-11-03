const STATUS = ['ok', 'invalid_argument', 'invalid_handle', 'invalid_page', 'capacity', 'open_error', 'extract_error', 'resource_limit'];

export class PDFParserError extends Error {
    constructor(message, code, status) {
        super(message);
        this.name = 'PDFParserError';
        this.code = code;
        this.status = status;
    }
}

function positiveLimit(value, name) {
    if (!Number.isSafeInteger(value) || value <= 0 || value > 0x7fffffff) {
        throw new RangeError(`${name} must be a positive wasm32 byte limit`);
    }
    return value;
}

export function inputBytes(data) {
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (data instanceof Uint8Array) return data;
    throw new TypeError('PDF input must be an ArrayBuffer or Uint8Array');
}

/** Raw module owner. Each document borrows its copied input until closePDF. */
export class PDFParser {
    constructor({ wasmBytes, wasmUrl = new URL('pdf_parser.wasm', import.meta.url), fetch: fetcher = globalThis.fetch?.bind(globalThis),
        maxInputBytes = 32 * 1024 * 1024, maxOutputBytes = 16 * 1024 * 1024,
        maxDecodedStreamBytes = 32 * 1024 * 1024 } = {}) {
        this.maxInputBytes = positiveLimit(maxInputBytes, 'maxInputBytes');
        this.maxOutputBytes = positiveLimit(maxOutputBytes, 'maxOutputBytes');
        this.maxDecodedStreamBytes = positiveLimit(maxDecodedStreamBytes, 'maxDecodedStreamBytes');
        this.wasmUrl = wasmUrl;
        this.wasmBytes = wasmBytes;
        this.fetcher = fetcher;
        this.wasm = null;
        this.memory = null;
        this._initialization = null;
        this._failed = null;
        this._documents = new WeakMap();
    }

    init() {
        if (!this._initialization) {
            this._initialization = (async () => {
                let bytes = this.wasmBytes;
                if (bytes === undefined) {
                    const response = await this.fetcher(this.wasmUrl);
                    if (!response.ok) throw new PDFParserError(`WASM download failed: HTTP ${response.status}`, 'http_error');
                    bytes = await response.arrayBuffer();
                }
                const { instance } = await WebAssembly.instantiate(bytes, {});
                const wasm = instance.exports;
                if (wasm.pdf_parser_wasm_abi_version?.() !== 2 || !(wasm.memory instanceof WebAssembly.Memory)) {
                    throw new PDFParserError('Unsupported pdf-parser WASM ABI (expected 2)', 'abi_mismatch');
                }
                for (const name of ['wasm_alloc', 'wasm_free', 'pdf_parser_wasm_open', 'pdf_parser_wasm_close',
                    'pdf_parser_wasm_page_count', 'pdf_parser_wasm_error_count', 'pdf_parser_wasm_extract_page', 'pdf_parser_wasm_extract_all']) {
                    if (typeof wasm[name] !== 'function') throw new PDFParserError(`Missing WASM export: ${name}`, 'abi_mismatch');
                }
                this.wasm = wasm;
                this.memory = wasm.memory;
                return this;
            })();
        }
        return this._initialization;
    }

    _ready() {
        if (this._failed) throw this._failed;
        if (!this.wasm) throw new PDFParserError('Await parser.init() before using the parser', 'not_ready');
    }

    _call(name, ...args) {
        this._ready();
        try { return this.wasm[name](...args); }
        catch (error) {
            // A trap can invalidate native invariants. Dispose this owner instead of reentering it.
            if (error instanceof WebAssembly.RuntimeError) this._failed = error;
            throw error;
        }
    }

    _status(status, operation) {
        if (status !== 0) throw new PDFParserError(`${operation}: ${STATUS[status] ?? 'unknown_status'}`, STATUS[status] ?? 'unknown_status', status);
    }

    alloc(size) {
        this._ready();
        positiveLimit(size, 'allocation size');
        const ptr = this._call('wasm_alloc', size);
        if (!ptr) throw new PDFParserError('Guest allocation refused', 'resource_limit', 7);
        return ptr;
    }

    free(ptr, size) {
        if (ptr && !this._failed) this._call('wasm_free', ptr, size);
    }

    readString(ptr, len) {
        return new TextDecoder().decode(new Uint8Array(this.memory.buffer, ptr, len));
    }

    _document(doc, allowClosed = false) {
        const state = this._documents.get(doc);
        if (!state) throw new PDFParserError('Document belongs to another parser', 'invalid_handle', 2);
        if (state.closed && !allowClosed) throw new PDFParserError('Document is closed', 'invalid_handle', 2);
        this._ready();
        return state;
    }

    openPDF(data) {
        this._ready();
        const bytes = inputBytes(data);
        if (bytes.byteLength === 0) throw new PDFParserError('PDF input is empty', 'invalid_argument', 1);
        if (bytes.byteLength > this.maxInputBytes) throw new PDFParserError('PDF input exceeds maxInputBytes', 'resource_limit', 7);
        const ptr = this.alloc(bytes.byteLength);
        let handle = 0;
        let out = 0;
        let published = false;
        try {
            new Uint8Array(this.memory.buffer, ptr, bytes.byteLength).set(bytes);
            out = this.alloc(4);
            this._status(this._call('pdf_parser_wasm_open', ptr, bytes.byteLength, this.maxDecodedStreamBytes, out), 'Open PDF');
            handle = new DataView(this.memory.buffer).getUint32(out, true);
            const doc = Object.freeze({ handle, dataPtr: ptr, dataLen: bytes.byteLength });
            this._documents.set(doc, { handle, ptr, len: bytes.byteLength, closed: false });
            published = true;
            return doc;
        } finally {
            try { this.free(out, 4); }
            finally {
                if (!published) {
                    try { if (handle && !this._failed) this._call('pdf_parser_wasm_close', handle); }
                    finally { this.free(ptr, bytes.byteLength); }
                }
            }
        }
    }

    closePDF(doc) {
        const state = this._documents.get(doc);
        if (!state) throw new PDFParserError('Document belongs to another parser', 'invalid_handle', 2);
        if (state.closed) return;
        state.closed = true;
        try {
            if (!this._failed) this._status(this._call('pdf_parser_wasm_close', state.handle), 'Close PDF');
        } finally { this.free(state.ptr, state.len); }
    }

    _count(doc, name) {
        const state = this._document(doc);
        const out = this.alloc(4);
        try {
            this._status(this._call(name, state.handle, out), 'Read document count');
            return new DataView(this.memory.buffer).getUint32(out, true);
        } finally { this.free(out, 4); }
    }

    getPageCount(doc) { return this._count(doc, 'pdf_parser_wasm_page_count'); }
    getErrorCount(doc) { return this._count(doc, 'pdf_parser_wasm_error_count'); }

    _extract(doc, pageNum) {
        const state = this._document(doc);
        if (pageNum !== undefined && (!Number.isInteger(pageNum) || pageNum < 0 || pageNum > 0x7fffffff)) {
            throw new PDFParserError('Invalid page index', 'invalid_page', 3);
        }
        const out = this.alloc(8);
        let ptr = 0, len = 0;
        try {
            const status = pageNum === undefined
                ? this._call('pdf_parser_wasm_extract_all', state.handle, this.maxOutputBytes, out, out + 4)
                : this._call('pdf_parser_wasm_extract_page', state.handle, pageNum, this.maxOutputBytes, out, out + 4);
            this._status(status, 'Extract PDF');
            const view = new DataView(this.memory.buffer);
            ptr = view.getUint32(out, true);
            len = view.getUint32(out + 4, true);
            if (len === 0) return '';
            return this.readString(ptr, len);
        } finally {
            try { this.free(ptr, len); }
            finally { this.free(out, 8); }
        }
    }

    extractPage(doc, pageNum) { return this._extract(doc, pageNum); }
    extractAll(doc) { return this._extract(doc); }

    extractDocument(data) {
        const doc = this.openPDF(data);
        try {
            const pageCount = this.getPageCount(doc);
            const text = this.extractAll(doc);
            return { pageCount, text, warningCount: this.getErrorCount(doc) };
        } finally { this.closePDF(doc); }
    }
}
