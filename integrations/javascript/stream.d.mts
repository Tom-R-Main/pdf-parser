import type { RichPdfDocument, OcrLimits } from './extract.mjs';
/** Global artifact IDs and page index; source positions are local to this page.
 * Delivered pages remain provisional until the extraction receipt succeeds. */
export interface RichPdfPage extends RichPdfDocument {
  pageIndex: number;
  sourceTextScope: 'page';
  streamComplete: false;
}
export interface StreamExtractionOptions {
  /** Opt in to exact-span glyph/replacement-group geometry. */
  includeGlyphGeometry?: boolean;
  /** Maximum decoded bytes in each native PDF stream. */
  maxDecodedStreamBytes?: number;
  binaryPath: string;
  onPage: (page: RichPdfPage) => void | Promise<void>;
  timeoutMs?: number;
  maxOutputBytes?: number;
  maxPageBytes?: number;
  maxRecordBytes?: number;
  maxRecords?: number;
  maxPages?: number;
  /** Live allocations through the adaptive page allocator; not process RSS. */
  maxNativePageMemoryBytes?: number;
  signal?: AbortSignal;
  enableOcr?: boolean;
  ocrLimits?: OcrLimits;
  allowPartial?: boolean;
}
export interface StreamExtractionReceipt {
  complete: true;
  inputSha256: string;
  schemaVersion: string;
  pageCount: number;
  records: number;
  outputBytes: number;
  artifactCounts: Record<string, number>;
}
/** Retains one page, a bounded identity set and compact section annotations;
 * caller-retained pages and process RSS are outside these byte budgets.
 * No receipt on partial failure. */
export function extractPdfPages(buffer: Uint8Array, options: StreamExtractionOptions): Promise<StreamExtractionReceipt>;
