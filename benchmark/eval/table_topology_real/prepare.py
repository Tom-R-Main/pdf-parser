#!/usr/bin/env python3
"""Copy hash-verified local originals into the ignored evaluation source cache."""
import argparse
import json
import os
from pathlib import Path
import tempfile

from verify import DEFAULT_SOURCE_ROOT, ROOT, basename, load_corpus, sha


def prepare_sources(source_root, output, sources):
    source_root, output = Path(source_root), Path(output)
    if source_root.resolve() == output.resolve():
        raise ValueError("source and destination must differ")
    if not isinstance(sources, list) or not sources:
        raise ValueError("empty source inventory")
    names = set()
    # Check the complete inventory before copying anything.
    for source in sources:
        name = source.get("filename")
        if not basename(name) or name in names:
            raise ValueError("invalid or duplicate source basename")
        names.add(name)
        original = source_root / name
        if original.is_symlink() or not original.is_file() or sha(original) != source["sha256"]:
            raise ValueError("wrong local source hash: " + name)
        destination = output / name
        if destination.is_symlink() or (destination.exists() and (not destination.is_file() or sha(destination) != source["sha256"])):
            raise ValueError("refusing to replace destination: " + name)
    output.mkdir(parents=True, exist_ok=True)
    result = []
    for source in sources:
        name = source["filename"]
        original, destination = source_root / name, output / name
        reused = destination.exists()
        if not reused:
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(prefix=".prepare-", dir=output, delete=False) as handle:
                    temporary = Path(handle.name)
                    with original.open("rb") as input_file:
                        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
                            handle.write(chunk)
                    handle.flush()
                    os.fsync(handle.fileno())
                if sha(temporary) != source["sha256"] or sha(original) != source["sha256"]:
                    raise ValueError("source changed while preparing: " + name)
                # Atomic no-clobber publication; never replace an existing file.
                try:
                    os.link(temporary, destination)
                except FileExistsError:
                    if destination.is_symlink() or not destination.is_file() or sha(destination) != source["sha256"]:
                        raise ValueError("destination appeared with wrong hash: " + name)
                    reused = True
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        if sha(original) != source["sha256"] or sha(destination) != source["sha256"]:
            raise ValueError("post-copy source/destination hash mismatch: " + name)
        result.append(dict(id=source["id"], filename=name, sha256=source["sha256"], reused=reused))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_SOURCE_ROOT)
    args = parser.parse_args()
    sources, _, _ = load_corpus(ROOT)
    result = prepare_sources(args.source_root, args.output, sources)
    print(json.dumps(dict(status="prepared", output=str(args.output), sources=result), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
