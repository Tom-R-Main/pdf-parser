# Changelog

## Unreleased: 0.4.0-dev

### Added

- Schema 0.20 adds conservative block section ancestry and chunk section owners,
  with document-global heading IDs shared by batch and streaming output.
- Optional source-range glyph geometry retains native quads and indivisible
  ligatures. ActualText replacements keep group bounds without invented quads.
- `extract-adaptive --max-decoded-stream-bytes` bounds each decoder/filter and
  predictor stage, including embedded fonts and lazy object streams.
- JavaScript adapters accept schema 0.20 and expose geometry and decoder-limit
  options. Streaming checks cross-page section references before completion.
- Deterministic CLI controls cover cross-format table identity, quote geometry,
  decoder refusal, section ancestry, long numbering, and outline cycles.

- Frozen statement drawings check section labels, directional wrapped rows,
  indentation, sparse amounts and narrative boundaries through both JSONL
  formats. Independent physical row envelopes reject incorrect attachments.

- Independent development drawings check separated table regions, persistent
  financial columns, exact source ownership and surrounding prose through both
  public JSONL formats. Previously observed real-document holdouts stay frozen.

- A source-bound real-document table pack freezes selected merged headers and
  continuation controls across separate development and holdout issuers. Local
  original PDFs stay outside Git; failed qualifications remain evidence.

- Frozen development and holdout suites check table topology, exact cell source
  ownership, and emitted reading order independently of graph diagnostics.
- A project-local build monitor bounds observed compiler-cache allocation and
  preserves logs and receipts outside the cache.
- Schema 0.18 page geometry and pixel-to-PDF transforms preserve raw PDF
  coordinates through quarter-turn OCR, CropBox and UserUnit handling.
- Schema 0.19 page and region route evidence explains bounded vector candidates
  and their regional OCR requests. Public records retain counters, limits and
  exact candidate bounds, including candidates sharing a bitmap crop.
- JavaScript adapters validate the new contracts and expose coordinate mapping
  helpers while preserving text, chunk origins and source locators.
- Small reproducible outlined-text fixtures and negative controls cover native
  clipping, transformed Forms, rules, highlights, logos and resource refusal.

### Fixed

- Batch and streaming extraction share one bounded table-continuation policy.
  Partial headers, missing evidence, page gaps, and intervening tables abstain.
- Native line grouping distinguishes opposite writing directions, including
  vertical text, while retaining source text and provenance.
- Resource refusals propagate through permissive decode recovery. The order of
  `--permissive` and an explicit decoder-limit flag cannot clear that limit.
- Deep numbered headings saturate before the counter and PART offset can
  overflow. Outline traversal detects repeated references and separately
  bounds recursion, retaining later siblings and readable page text.

- Schema 0.19.4 assembles corroborated section rows and wrapped labels without
  suppressing refused native sources through heuristic fallback. Transformed
  text uses private scale evidence while retaining public declared font sizes;
  padded currency dashes preserve their literal text and amount columns.
- Schema 0.19.3 isolates table regions and assigns source membership explicitly,
  retaining unrelated native text and distinguishing cells in separate regions.
- The real-document gate rejects array-shaped public table bounds while retaining
  the independently frozen truth coordinate format.

- Schema 0.19.2 keeps batch debug assets bound to original document pages when
  extraction selects a window starting after page one.

- Schema 0.19.1 keeps reconstructed table evidence at cell granularity, assigns
  shared-rule text once, and retains prose surrounding a promoted table.
- Legacy native ordering resets columns at corroborated section headings.
- Topology comparison checks physical grid dimensions, streaming verification
  checks page identity, and exact financial tokens cannot be confused with
  substrings inside other values.
- Rotated OCR preserves recognized word order. Inferred tables on rotated pages
  remain withheld until their topology is qualified.
- Partially clipped native spans no longer suppress outlines outside their clip.
- Exhausted native coverage accounting abstains instead of publishing zero
  coverage as complete evidence.
- OCR text elsewhere in a reused bitmap crop cannot mark a disjoint vector
  candidate recovered. Recovery remains text availability, with completeness
  unverified.

### Changed

- README now leads with a runnable local example, output choices, and fit limits.
  Detailed commands and architecture live in linked guides; broad unmeasured
  comparisons with other parsers have been removed.

- CI runs adapter test files serially to avoid process-start deadline contention
  observed during concurrent local verification.
- Vector collection and classification retain explicit work bounds. These
  bounds exclude initial PDF decompression and do not establish a whole-process
  memory limit.
