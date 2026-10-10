export type ChunkStrategy = 'legacy' | 'hybrid' | 'light';
export type ChunkMetadata = { lineage?: string[]; [key: string]: unknown };
export type ComposeChunksWithOriginsArgs = {
  text: string;
  strategy?: ChunkStrategy;
  /** Four UTF-16 code units per token approximation; default 256. */
  maxTokens?: number;
  /** Default 32; clamped below the structural window to guarantee progress. */
  overlapTokens?: number;
  metadata?: ChunkMetadata;
};
export type ChunkWithOrigin = {
  index: number;
  body: string;
  /** Half-open offsets into the original, untrimmed input string. */
  startOffset: number;
  endOffset: number;
  offsetUnit: 'utf16_code_unit';
  /** SHA-256 of the original input, encoded as UTF-8. */
  sourceTextSha256: string;
  normalization: 'collapse_whitespace_trim';
  metadata: ChunkMetadata & { lineage: string[] };
};
export function composeChunksWithOrigins(args: ComposeChunksWithOriginsArgs): ChunkWithOrigin[];
