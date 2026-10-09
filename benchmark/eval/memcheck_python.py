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
    from zpdf._ffi import _find_library, ffi, lib

    requested = Path(os.environ["PDF_PARSER_LIB"]).resolve()
    resolved = Path(_find_library()).resolve()
    check(requested == resolved, "binding resolved a different shared library")
    ffi.cdef("unsigned long long pdf_parser_memcheck_live_allocations(void); "
             "unsigned long long pdf_parser_memcheck_live_bytes(void);")

    def totals():
        return (int(lib.pdf_parser_memcheck_live_allocations()), int(lib.pdf_parser_memcheck_live_bytes()))

    def released():
        check(totals() == (0, 0), "parser allocations remain after operation: " + str(totals()))

    released()
    if sys.argv[1:] == ["--control"]:
        # Import the identical binding and library without creating a document.
        # A failing control is a runtime/tool qualification failure; it is never
        # subtracted from the extraction lane or accepted as a passing check.
        print(json.dumps({"resolved_library": str(resolved), "live_native_allocations": 0, "live_native_bytes": 0, "document_cycles": 0,
                          "adaptive_calls": 0, "status": "passed", "control": True}))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--counter-leak-control":
        with Document(Path(sys.argv[2]).resolve()) as doc:
            check(doc.page_count > 0, "no pages in counter control")
            check(totals()[0] > 0 and totals()[1] > 0, "open document invisible to counters")
            try:
                released()
            except RuntimeError:
                detected = True
            else:
                detected = False
        released()
        check(detected, "lifetime check accepted a retained document")
        print(json.dumps({"retained_document_rejected": True, "cleanup_verified": True}))
        raise SystemExit(78)
    check(len(sys.argv) == 2, "expected one fixture path or --control")
    fixture = Path(sys.argv[1]).resolve()
    for _ in range(3):
        for source in (fixture, fixture.read_bytes()):
            with Document(source) as doc:
                document_totals = totals()
                check(document_totals[0] > 0 and document_totals[1] > 0, "open document invisible to counters")
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
            released()
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
                released()
        for bad in (b"not a PDF", b"%PDF-1.7\n"):
            with Document(bad) as doc:
                check(doc.page_count == 0, "legacy permissive recovery changed")
            released()
            try:
                extract_adaptive(bad, strict=True, permissive=False)
            except ExtractionError:
                pass
            else:
                raise RuntimeError("malformed/truncated input accepted")
            released()
    print(json.dumps({"resolved_library": str(resolved), "document_cycles": 6,
                      "adaptive_calls": 12, "malformed_inputs": 6, "live_native_allocations": 0,
                      "live_native_bytes": 0, "status": "passed"}))


if __name__ == "__main__":
    main()
