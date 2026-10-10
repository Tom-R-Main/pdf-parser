const flags = { maxImagePixels: '--ocr-max-image-pixels', maxImageBytes: '--ocr-max-image-bytes',
  maxRegionsPerPage: '--ocr-max-regions', maxAttemptsPerPage: '--ocr-max-attempts' };

export function ocrArguments(limits) {
  if (limits === undefined) return [];
  if (limits === null || typeof limits !== 'object' || Array.isArray(limits)) throw new TypeError('OCR limits must be an object');
  if (Object.keys(limits).some(key => !Object.hasOwn(flags, key))) throw new RangeError('Unknown OCR limit');
  const args = [];
  for (const [key, flag] of Object.entries(flags)) {
    if (limits[key] === undefined) continue;
    if (!Number.isSafeInteger(limits[key]) || limits[key] < 1) throw new RangeError('OCR limits must be positive safe integers');
    args.push(flag, String(limits[key]));
  }
  return args;
}
