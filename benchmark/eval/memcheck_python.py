"""Exercise the real Python binding against an explicitly selected shared library."""
import json
import os
from pathlib import Path
import sys


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    from zpdf import Document, extract_adaptive, ExtractionError, PageNotFoundError
    from zpdf._ffi import _find_library

    fixture = Path(sys.argv[1]).resolve()
    requested = Path(os.environ["PDF_PARSER_LIB"]).resolve()
    resolved = Path(_find_library()).resolve()
    check(requested == resolved, "binding resolved a different shared library")
    for _ in range(3):
        for source in (fixture, fixture.read_bytes()):
            with Document(source) as doc:
                check(doc.page_count > 0, "no pages")
                check("Clean born digital" in doc.extract_page(0), "page text missing")
                check("Clean born digital" in doc.extract_all(), "document text missing")
                check(any(span.text for span in doc.extract_bounds(0)), "bounds missing")
                try:
                    doc.extract_page(-1)
                except PageNotFoundError:
                    pass
                else:
                    raise RuntimeError("invalid page accepted")
            doc.close()
            try:
                _ = doc.page_count
            except ValueError:
                pass
            else:
                raise RuntimeError("closed document accepted")
        for fmt in ("artifact-jsonl", "stream-jsonl"):
            for source in (fixture, fixture.read_bytes()):
                records = [json.loads(line) for line in extract_adaptive(source, format=fmt).splitlines()]
                check(records[0]["record_type"] == "document_manifest", "manifest ordering")
                check("Clean born digital" in json.dumps(records), "adaptive text missing")
                if fmt == "stream-jsonl":
                    check(records[-1].get("event_type") == "document_finished", "stream teardown missing")
        for bad in (b"not a PDF", b"%PDF-1.7\n"):
            with Document(bad) as doc:
                check(doc.page_count == 0, "legacy permissive recovery changed")
            try:
                extract_adaptive(bad, strict=True, permissive=False)
            except ExtractionError:
                pass
            else:
                raise RuntimeError("malformed/truncated input accepted")
    print(json.dumps({"resolved_library": str(resolved), "document_cycles": 6,
                      "adaptive_calls": 12, "malformed_inputs": 6, "status": "passed"}))


if __name__ == "__main__":
    main()
