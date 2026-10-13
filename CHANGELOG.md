# Changelog

## Unreleased: 0.4.0-dev

### Added

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

- CI runs adapter test files serially to avoid process-start deadline contention
  observed during concurrent local verification.
- Vector collection and classification retain explicit work bounds. These
  bounds exclude initial PDF decompression and do not establish a whole-process
  memory limit.
