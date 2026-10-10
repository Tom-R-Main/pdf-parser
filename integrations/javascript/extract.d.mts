export type ExtractionErrorCode = 'protocol' | 'unavailable' | 'timeout' | 'output_limit' | 'memory_limit' | 'aborted' | 'crashed' | 'document' | 'cleanup' | 'callback';
export class PdfExtractionError extends Error {
  readonly code: ExtractionErrorCode;
  cleanupError?: PdfExtractionError;
  constructor(code: ExtractionErrorCode, message: string, options?: ErrorOptions);
}
export interface ExtractionOptions {
  /** Host-owned executable selection. No environment or default path discovery. */
  binaryPath: string;
  timeoutMs?: number;
  maxOutputBytes?: number;
  signal?: AbortSignal;
  /** Defaults to false. Requires host-installed OCR tools when enabled. */
  enableOcr?: boolean;
}
export interface TextView {
  text_view_id: string;
  kind: 'reconciled_span' | 'reconciled_block' | 'rag_chunk';
  offset_unit: 'utf8_byte';
  range_convention: 'half_open';
  normalization: 'none';
  text_sha256: string;
}
export interface Provenance {
  document_id: string;
  source_id: string | null;
  input_sha256: string;
  /** Specialist compatibility ids name a class. Their record-owned request_id,
   * attempt_id, response_id or specialist_result_id provides unique identity. */
  artifact_id: string;
  span_ids?: string[];
  block_ids?: string[];
  chunk_ids?: string[];
  [key: string]: unknown;
}
export interface ArtifactRecord {
  schema_name: string;
  schema_version: string;
  record_type: string;
  document_id: string;
  source_id: string | null;
  provenance: Provenance;
  [key: string]: unknown;
}
export interface ManifestRecord extends ArtifactRecord {
  record_type: 'document_manifest';
  page_count: number;
  input_sha256: string;
  artifact_counts: { spans: number; blocks: number; rag_chunks: number; [key: string]: unknown };
  text_contract: { offset_unit: 'utf8_byte'; range_convention: 'half_open'; page_index_base: 0;
    geometry: { coordinate_space: 'pdf_user_space'; unit: 'point'; highlight_precision: 'span_bbox'; display_transform: null } };
}
/** Unchanged PDF-space bbox; these are not browser or screen coordinates. */
export interface PdfBBox { x0: number; y0: number; x1: number; y1: number }
export interface SpanRecord extends ArtifactRecord {
  record_type: 'span';
  span_id: string;
  reconciled_block_id?: string | null;
  page_index: number;
  bbox: PdfBBox;
  text: string;
  text_view: TextView;
}
export interface ByteSourceSegment {
  text_start_byte: number;
  text_end_byte: number;
  source_start_byte: number | null;
  source_end_byte: number | null;
}
export interface BlockRecord extends ArtifactRecord {
  record_type: 'block';
  block_id: string;
  page_index: number;
  bbox: PdfBBox;
  text: string;
  text_view: TextView;
  source_map: (ByteSourceSegment & { source_span_id: string | null })[];
}
export interface ChunkRecord extends ArtifactRecord {
  record_type: 'rag_chunk';
  chunk_id: string;
  content: string;
  page_start: number;
  page_end: number;
  source_span_ids: string[];
  source_block_ids: string[];
  text_view: TextView;
  source_map: (ByteSourceSegment & { source_block_id: string | null })[];
}
export interface SourceTextSegment {
  /** Half-open UTF-16 positions in RichPdfDocument.sourceText. */
  start: number;
  end: number;
  sourceBlockId: string | null;
  sourceSpanId: string | null;
  pageIndex: number | null;
  bbox: PdfBBox | null;
  /** Half-open UTF-16 positions in the referenced span; null for synthetic text. */
  sourceStart: number | null;
  sourceEnd: number | null;
}
export interface RichPdfDocument {
  rawJsonl: string;
  records: ArtifactRecord[];
  manifest: ManifestRecord;
  inputSha256: string;
  spans: SpanRecord[];
  blocks: BlockRecord[];
  chunks: ChunkRecord[];
  tables: TableRecord[];
  pageOutcomes: PageOutcome[];
  /** Exact block texts in artifact order, joined by synthetic two-newline separators. */
  sourceText: string;
  sourceTextSha256: string;
  sourceMap: SourceTextSegment[];
  /** Legacy table block refs can predate reconciliation. These refs are
   * unverified metadata and never contribute to source-text locators. */
  unresolvedProvenanceLinks: { recordType: 'table'; artifactId: string; field: 'block_ids'; id: string }[];
  offsetUnit: 'utf16_code_unit';
  rangeConvention: 'half_open';
  normalization: 'none';
  /** A valid map proves text identity, not full document extraction. */
  pageCoverage: 'unverified';
}
export interface TableCellRecord {
  cell_id: string;
  page_index: number;
  text: string;
  raw_text: string;
  row: number;
  column: number;
  rowspan: number;
  colspan: number;
  role: string;
  bbox: PdfBBox;
  source_span_ids: string[];
  reconciled_block_ids?: string[];
  [key: string]: unknown;
}
export interface TableRecord extends ArtifactRecord {
  table_id: string;
  page_index: number;
  source_span_ids: string[];
  /** Authoritative 0.15 links; legacy layout/provenance ids remain separate. */
  reconciled_block_ids?: string[];
  rows: { cells: TableCellRecord[]; [key: string]: unknown }[];
}
export interface PageOutcome {
  pageIndex: number;
  status?: 'text_available' | 'empty_unverified' | 'recovery_required' | 'recovery_failed' | 'recovered';
  completeness?: 'unverified';
  recovery_state?: 'not_required' | 'not_invoked' | 'completed' | 'empty' | 'unavailable' | 'failed' | 'timeout' | 'invalid_output';
  requested_recovery?: boolean;
  native_span_count?: number;
  recognized_span_count?: number;
  unresolved_region_count?: number;
}
export function utf8BoundaryMap(text: string): Map<number, number>;
export function parseArtifactJsonl(rawJsonl: string, options: { inputSha256: string; expectedSourceId?: string | null }): RichPdfDocument;
export function extractPdfDocument(buffer: Uint8Array, options: ExtractionOptions): Promise<RichPdfDocument>;
/** Uses the adaptive block projection; native extract whitespace can differ. */
export function extractPdfText(buffer: Uint8Array, options: ExtractionOptions): Promise<string>;
export function locateSourceRange(document: RichPdfDocument, startOffset: number, endOffset: number, options: { sourceTextSha256: string }): {
  startOffset: number;
  endOffset: number;
  sourceTextSha256: string;
  offsetUnit: 'utf16_code_unit';
  rangeConvention: 'half_open';
  segments: SourceTextSegment[];
};
export function projectPromptText(document: RichPdfDocument, maxUtf16Units: number): {
  text: string;
  truncated: boolean;
  sourceTextSha256: string;
  sourceStart: 0;
  sourceEnd: number;
  offsetUnit: 'utf16_code_unit';
};
