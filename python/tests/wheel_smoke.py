"""Functional smoke test for an installed platform wheel."""

from __future__ import annotations

import json
import sys
import zipfile
from importlib import metadata
from pathlib import Path

import zpdf
from zpdf import _ffi


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: wheel_smoke.py WHEEL FIXTURE EXPECTED_LIBRARY")

    wheel = Path(sys.argv[1]).resolve()
    fixture = Path(sys.argv[2]).resolve()
    expected_library = sys.argv[3]
    package_dir = Path(zpdf.__file__).resolve().parent
    selected_library = Path(_ffi._find_library()).resolve()

    assert selected_library.parent == package_dir
    assert selected_library.name == expected_library
    assert "-none-any.whl" not in wheel.name

    distribution = metadata.distribution("pdf-parser")
    native_version = _ffi.ffi.string(_ffi.lib.pdf_parser_version()).decode("ascii")
    package_version = (
        native_version[:-4] + ".dev0" if native_version.endswith("-dev") else native_version
    )
    assert distribution.version == zpdf.__version__ == package_version

    with zipfile.ZipFile(wheel) as archive:
        native_members = [
            name
            for name in archive.namelist()
            if name.endswith((".so", ".dylib", ".dll"))
        ]
    assert native_members == [f"zpdf/{expected_library}"], native_members

    with zpdf.Document(fixture) as document:
        text = document.extract_all()
    assert "Clean born digital text" in text

    artifacts = zpdf.extract_adaptive(
        fixture,
        source_id="wheel-smoke",
        format="artifact-jsonl",
    )
    manifest = json.loads(artifacts.splitlines()[0])
    assert manifest["record_type"] == "document_manifest"
    assert manifest["parser_version"] == native_version


if __name__ == "__main__":
    main()
