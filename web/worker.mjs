import { PDFParser } from './pdf-parser.mjs';

let parser = null;

self.onmessage = async ({ data }) => {
    if (!Number.isSafeInteger(data?.id) || data.id <= 0) return;
    try {
        let result;
        if (data.type === 'INIT') {
            if (parser) throw new Error('Parser already initialized');
            parser = new PDFParser({ ...data.options, wasmUrl: data.wasmUrl });
            await parser.init();
            result = { abiVersion: 2 };
        } else if (data.type === 'EXTRACT') {
            if (!parser?.wasm) throw new Error('Parser not initialized');
            result = parser.extractDocument(data.bytes);
        } else throw new Error('Unknown parser worker request');
        self.postMessage({ id: data.id, type: 'RESULT', result });
    } catch (error) {
        const fatal = error instanceof WebAssembly.RuntimeError || data.type === 'INIT';
        self.postMessage({ id: data.id, type: 'ERROR', fatal, error: {
            name: error?.name ?? 'Error', message: error?.message ?? String(error), code: error?.code, status: error?.status,
        } });
    }
};
