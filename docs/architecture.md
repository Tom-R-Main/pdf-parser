# Architecture

The PDF kernel, adaptive pipeline, public output contract, and evaluation tools
have separate responsibilities. A host can use the deterministic CLI/JSONL
boundary without adopting the internal Zig types.

## PDF kernel

`src/root.zig` exposes the document API. It opens files or caller-owned memory,
resolves PDF objects, and owns document-lifetime caches. Shorter-lived page work
uses explicit scratch allocators.

| Responsibility | Source |
| --- | --- |
| Objects, cross-references, and pages | `parser.zig`, `xref.zig`, `pagetree.zig` |
| Stream decoding and encryption | `decompress.zig`, `encryption.zig` |
| Fonts, Unicode mappings, and glyph placement | `encoding.zig`, `font_mapping.zig`, `interpreter.zig` |
| Paint, clipping, Forms, and tagged structure | `paint.zig`, `form_scope.zig`, `structtree.zig` |
| Native line reconstruction and layout | `native_layout.zig`, `layout.zig` |

Native glyph evidence includes source identity, transforms, placement, and
paint/clipping information. Semantic ActualText replacements retain group
identity rather than inventing a character-to-glyph correspondence.

## Adaptive pipeline

`adaptive.zig` combines native spans, layout blocks, and page/region complexity
signals. It records routing decisions, reconstructs supported table regions,
invokes configured specialists, and reconciles the resulting evidence.

- `complexity.zig` and `vector_routing.zig` identify routes and their reasons.
- `ocr.zig` handles local OCR adapters and crop lifecycles.
- `specialists.zig` and `specialist_protocol.zig` define specialist boundaries.
- `reconcile.zig` builds spans, blocks, chunks, and exact text source maps.
- `table_continuation.zig` shares bounded continuation decisions across formats.
- `section_hierarchy.zig` annotates existing block identities without reordering text.

OCR, table, and formula models stay outside the kernel. Failed or ambiguous
recovery retains available native evidence and explicit outcomes; it does not
establish complete coverage. Native layout may use a readable Poppler fallback
when its quality gate fails, with the external source recorded.

Reading order uses existing structure and geometric/native fallbacks. The
experimental graph has separate diagnostic gates and has not been promoted to
the default path. A passing text inventory or synthetic order fixture cannot
prove semantic order for every document.

## Public boundaries

`schema.zig` renders the versioned records. `stream.zig` emits them page by page
with lifecycle events; `adapter.zig` is the shared host entry point. CLI, C ABI,
Python, JavaScript, HTTP, and WASM surfaces expose different calling conventions
over the parser.

Treat [the output schema](output-schema.md) as the public artifact contract.
Text offsets, coordinate transforms, source IDs, and completion states are
explicit. Artifact-local IDs must be bound to the input and text-view hashes;
they are not guaranteed to survive another extraction run or parser version.

## Quality boundary

Small checked-in fixtures cover deterministic correctness. Frozen development
and holdout packs score table ownership, physical cell geometry, and public
reading order separately. Larger or redistribution-unclear PDFs stay in ignored
cache paths. External parsers are comparator lanes, not universal ground truth.

See [evaluation](../benchmark/eval/README.md), [benchmarking](benchmarking.md),
and [memory checks](memory-checks.md) for the commands and their limits.
