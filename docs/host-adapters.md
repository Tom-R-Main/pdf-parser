# Neutral JavaScript host adapters

The dependency-free modules under `integrations/javascript` make phase 1
available to both host projects. This change writes only to pdf-parser. It does
not wire a host route, update a deployed parser pin, change stored documents,
or re-embed a corpus.

Use Node 22 or newer. Import the modules directly from a vendored parser checkout
or an explicit local package path; nothing is downloaded or published here.
The `.d.mts` declarations provide the TypeScript boundary. The host continues
to own executable discovery, authorization, storage, acceptance and deployment.

```js
import {
  composeChunksWithOrigins,
  extractPdfDocument,
  locateSourceRange,
  projectPromptText,
} from './integrations/javascript/index.mjs';

const document = await extractPdfDocument(pdfBytes, {
  binaryPath: approvedParserBinary,
  timeoutMs: 45_000,
  maxOutputBytes: 25 * 1024 * 1024,
});
const chunks = composeChunksWithOrigins({
  text: document.sourceText,
  maxTokens: 260,
  overlapTokens: 40,
  strategy: 'hybrid',
});
const indexedChunks = chunks.map(chunk => ({
  ...chunk,
  locator: locateSourceRange(document, chunk.startOffset, chunk.endOffset, {
    sourceTextSha256: chunk.sourceTextSha256,
  }),
}));
const prompt = projectPromptText(document, 50_000);
```

## Overlap-aware composition

`composeChunksWithOrigins({text, maxTokens, overlapTokens, strategy, metadata})`
returns chunk bodies with `startOffset`, `endOffset`, `offsetUnit`, the exact
untrimmed input's SHA-256, normalization policy and metadata lineage.

Origins are carried through structural windows, trimming, whitespace collapse
and semantic sentence ranges. Overlap can start inside the preceding chunk;
there is no forward end cursor or search for the chunk body. Repeated paragraphs
therefore retain their actual positions. Half-open UTF-16 boundaries never split
surrogate pairs. Empty text returns no chunks; malformed Unicode and invalid
budgets fail explicitly.

The token budget is an approximation of four UTF-16 units per token, not a model
tokenizer. Defaults are 256/32 and hybrid; supply host settings explicitly.
Unlike the current host chunker, zero overlap stays zero and small windows have
no 200-character floor. Oversized overlap is clamped below the window and always
advances. Semantic punctuation handling also differs. This is an explicit new
chunker version, not a promise of identical chunk bodies or embedding identities.

For retrieval indexing, use these origins instead of rediscovering offsets in
research indexing. Existing UTF-16 offset columns can hold these ranges; record
the source text hash/view identity and chunker version in host metadata. PDF
page/span evidence comes from the rich document locator; ordinary text sources
can use the origin helper without PDF geometry. Keep existing RLS and scope
transactions. Rechunk/backfill and embedding decisions require their own bounded
host rollout; this library performs none.

## Rich extraction and compatible projections

`extractPdfDocument(bytes, options)` invokes the host-selected binary's
`extract-adaptive --format artifact-jsonl`. It snapshots input bytes before
asynchronous I/O, supplies the input SHA-256 as source identity, uses a private
0600 temporary PDF and removes scratch files on completion/failure. Default
limits are 45 seconds and 25 MiB. OCR is disabled by default;
`enableOcr:true` uses already-configured local OCR tools. Cancellation, timeout,
oversized output and process failures remain explicit.

The result retains the manifest, raw JSONL, all protocol records, spans, blocks
and parser chunks. Its `sourceText` is exact block text in artifact order joined
by synthetic `\n\n` separators, with its own SHA-256 and UTF-16 source map.
Parser byte offsets are translated at valid UTF-8 boundaries; byte positions
are never saved as JavaScript character offsets.

`extractPdfText` provides the string-shaped projection of that rich API. Its
adaptive whitespace/order may differ from the existing native `extract` lane.
An editorial application can add the rich result alongside its existing extractor and migrate
reference, chat and transcript callers individually; retain its current binary
resolver, failure-response policy, edition scoping and quote-safety checks.

Store the authoritative rich text/map before building prompts.
`projectPromptText(document, maxUtf16Units)` returns a bounded text projection,
truncation flag and source range/hash, without changing document text or offsets.
A stored-document size limit is a separate decision; do not claim a truncated
projection is the entire source.

## Locator and protocol acceptance

`locateSourceRange` validates the exact source-text hash and UTF-16 range, then
returns intersecting span/block/page evidence and synthetic gaps. Span bboxes
remain PDF-space boxes, not precise character quads or viewer pixels. Apply a
page-specific rotation/crop/display transform in the host. Synthetic whitespace
has null span geometry. Bind stored locators to `inputSha256`, source identity,
text hash/view and the record ids; do not resolve them against another run by
phrase alone.

`parseArtifactJsonl(rawJsonl, {inputSha256, expectedSourceId})` validates manifest-first batch
ordering, schema `0.14.x`/`0.15.x`, input/provenance identity, text hashes, range boundaries,
full source-map coverage, referenced artifact sets and page relationships. It
rejects truncated/malformed streams, forged synthetic text and mismatched source
views. This is a batch reader; use `extractPdfPages` for lifecycle streams.

`source_id` must be present and contain a nonempty string or null. Supply
`expectedSourceId` when the caller selected an external source identity; the
extraction adapter always binds it to the input hash supplied to the CLI.
For `0.14.x` only, chunks can carry an internal label when manifest/provenance
source identity is null. The reader retains that label as metadata; it cannot
override manifest, input hash or provenance identity. Current `0.15.x` records
must agree with the manifest, including null when no source id was supplied.

Specialist records retain their legacy shared provenance labels; uniqueness is
checked with their actual request/attempt/response/result ids. Some current table
provenance block references describe pre-reconciliation indices. The adapter
preserves those raw values and reports missing references as
`unresolvedProvenanceLinks`, rather than using them for source-text locators.
Core span/block/chunk maps remain strict. In schema `0.15.x`, `document.tables`
exposes table/cell `reconciled_block_ids` checked against owning source spans.
Span `reconciled_block_id` and ownership provenance must agree with block maps;
cells must share their table's page. Use these authoritative fields for links.

`PdfExtractionError.code` distinguishes `unavailable`, `timeout`, `output_limit`,
`memory_limit`, `aborted`, `crashed`, `document`, `protocol`, `callback` and `cleanup`. A cleanup failure
attached to an earlier error does not replace the original diagnosis. The host
maps these outcomes to its own user-facing messages and retry policy.

On macOS/Linux, timeout, cancellation and output limits close output pipes and
terminate descendants from leaves upward, allowing each live parent to reap its
children before terminating the private process group. This uses the local `ps`
inventory with a one-second cleanup grace period. An unavailable inventory or a
parent unable to reap attaches `cleanupError` to the original extraction error;
cleanup is then unqualified. Descendants that deliberately create a separate
session are outside that group. Other platforms kill the direct child and close
its pipes; process-tree cleanup is not qualified there.

The result deliberately reports `pageCoverage:'unverified'`. A valid process,
manifest or source map does not establish that every page/region was extracted.
Schema `0.15.x` adds `document.pageOutcomes` and page/region route `coverage`.
These distinguish retained text, empty unverified output, required/failed
recovery and recovered regions. The reader rejects out-of-document pages and
contradictory recovery states. Preserve unresolved assessments in intake and
retrieval policy. Paint/clipping evidence and regional OCR crops remain pending;
these assessments do not establish quote verification or publishing authority.

## Incremental pages and resource budgets

```js
import { extractPdfPages } from './integrations/javascript/index.mjs';

const receipt = await extractPdfPages(pdfBytes, {
  binaryPath,
  maxOutputBytes: 25 * 1024 * 1024,
  maxPageBytes: 4 * 1024 * 1024,
  maxNativePageMemoryBytes: 8 * 1024 * 1024,
  onPage: async (page) => {
    await persistProvisionalPage(page);
  },
});
await acceptCompletedStream(receipt);
```

`onPage` is required and awaited serially, providing stdout backpressure. Each
page has document-global artifact ids/page indices, but page-local source-text
offsets and hash, `sourceTextScope:'page'` and `streamComplete:false`. Bind each
locator to that page projection. Callbacks are provisional; only a returned
receipt with `complete:true`, validated lifecycle/counts and exit zero qualifies
stream completion. A later failure leaves previously delivered pages incomplete.

Defaults are 45 seconds, 25 MiB output, 4 MiB retained page JSONL, 1 MiB per
record, 100,000 records and 10,000 pages. Override with `timeoutMs`,
`maxOutputBytes`, `maxPageBytes`, `maxRecordBytes`, `maxRecords`, `maxPages` and
`signal`. Limits also cover callback waits. The adapter retains the current
page plus a bounded identity set; decoded objects have overhead beyond their
serialized size. Caller-retained pages and input bytes are outside these limits.

Optional `maxNativePageMemoryBytes` forwards the CLI's adaptive page allocation
budget. It excludes document caches/mappings, allocator metadata and child RSS.
The native CLI also exposes `--max-output-bytes` for aggregate serialization.
Neither limit is a whole-process memory cap. Native budget failures are surfaced
as `memory_limit`/`output_limit`, without a complete receipt.

## Adoption and verification

Readers limited to `0.11.x`/`0.13.x` must add
`0.15.x` with contract tests before changing their parser pin. The adapter retains
`0.14.x` reader support. Applications must pair
their adopted parser revision with the selected Zig 0.17/compiler/archive identities
and run its baseline CPU/runtime smoke lane. Formula children must echo the new
request schema version. Neither host is changed by this work.

Run the local adapter regressions and actual CLI composition test:

```sh
zig build --summary all
node --test integrations/javascript/*.test.mjs
zig build test --summary all
```

The real CLI test generates a two-page PDF with repeated same-MCID lines, then
checks rich extraction -> overlapping chunk origins -> page/span locator slices.
It reports a skip when no built executable exists; that skip does not qualify
the integration. Unit tests cover Unicode byte/unit translation, repeated
phrases, zero/large overlap, forged mappings, process limits, cancellation and
scratch cleanup. No host database, browser, deployment or paid model is exercised.
