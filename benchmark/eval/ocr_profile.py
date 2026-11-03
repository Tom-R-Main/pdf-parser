#!/usr/bin/env python3
"""Build and qualify an explicit, local Linux external-OCR arithmetic profile."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parents[2]
PINS = {
    "openjpeg": ("2.5.4", "https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz", "a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a"),
    "poppler": ("26.02.0", "https://poppler.freedesktop.org/poppler-26.02.0.tar.xz", "dded8621f7b2f695c91063aab1558691c8418374cd583501e89ed39487e7ab77"),
    "tesseract": ("5.5.2", "https://github.com/tesseract-ocr/tesseract/archive/refs/tags/5.5.2.tar.gz", "6235ea0dae45ea137f59c09320406f5888383741924d98855bd2ce0d16b54f21"),
}
MODEL_SHA256 = "7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"
PROBE_PDF = "benchmark/eval/corpus/scanned_typewritten/jpx-public-domain-map-cover.pdf"
PROBE_PDF_SHA256 = "58e3465bcb9823a610102b1d17f4ee71b7bcab94fb06b87bf0676ab70d0c8056"
PROBE_RGB_SHA256 = "c4e17205e5bf4fae81ec7f0b069f031c97ba350f02432f808240fed012847aeb"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_hash(path: Path, expected: str) -> None:
    if sha(path) != expected:
        raise ValueError(f"SHA256 mismatch: {path}")


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def require_cpu() -> None:
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "amd64"):
        raise ValueError("This profile requires Linux x86_64 with AVX and FMA")
    features = Path("/proc/cpuinfo").read_text().split()
    if "avx" not in features or "fma" not in features:
        raise ValueError("AVX/FMA CPU capability is required; no silent fallback")


def run(output: Path, label: str, argv: list, *, env=None, timeout=900) -> dict:
    started = time.monotonic()
    stdout, stderr = output / (label + ".stdout"), output / (label + ".stderr")
    timed_out = False
    with stdout.open("xb") as out, stderr.open("xb") as err:
        proc = subprocess.Popen(list(map(str, argv)), cwd=ROOT, env=env, stdout=out, stderr=err, start_new_session=True)
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        finally:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    result = dict(command=list(map(str, argv)), cwd=str(ROOT), exit_code=proc.returncode, timed_out=timed_out,
                  duration_seconds=round(time.monotonic() - started, 3), pid=proc.pid,
                  stdout=str(stdout), stderr=str(stderr), stdout_sha256=sha(stdout), stderr_sha256=sha(stderr), owned_group_cleanup=True)
    write_json(output / (label + ".receipt.json"), result)
    print(label, result["exit_code"], flush=True)
    return result


def checked(output: Path, label: str, argv: list, **kwargs) -> dict:
    result = run(output, label, argv, **kwargs)
    if result["exit_code"] or result["timed_out"]:
        raise RuntimeError(f"{label} failed; see {result['stderr']}")
    return result


def loaded_openjpeg(output: Path, executable: Path, library: Path, env: dict) -> dict:
    result = checked(output, "loaded-openjpeg", ["ldd", executable], env=env)
    lines = Path(result["stdout"]).read_text().splitlines()
    line = next((s for s in lines if "libopenjp2.so.7 =>" in s), "")
    if not line or Path(line.split("=>", 1)[1].strip().split()[0]).resolve() != library.resolve():
        raise ValueError("pdftoppm did not load the profile's OpenJPEG library")
    return dict(path=str(library.resolve()), sha256=sha(library), ldd_line=line.strip())


def wrapper(path: Path, executable: Path, variables: dict) -> None:
    path.write_text("#!/usr/bin/env python3\nimport os, sys\n"
                    f"executable = {str(executable)!r}\n"
                    f"env = os.environ | {variables!r}\n"
                    "os.execve(executable, [executable, *sys.argv[1:]], env)\n")
    path.chmod(0o755)


def verify_compile_flags(stage: str, commands: list) -> None:
    for item in commands:
        unsafe = any(flag in item["command"] for flag in ("-ffast-math", "-funsafe-math-optimizations", "-Ofast"))
        # Tesseract pins this option on one native dot-product implementation.
        # It is not a global option or part of the decoder contraction change.
        upstream_dotproduct = stage == "tesseract" and Path(item["file"]).parts[-3:] == ("src", "arch", "dotproduct.cpp")
        if unsafe and not upstream_dotproduct:
            raise ValueError("Unsafe global floating-point flags are forbidden in this profile")


def collect_compilers(output: Path, stage: str, directory: Path) -> dict:
    cache = directory / "CMakeCache.txt"
    commands = directory / "compile_commands.json"
    compilers = {}
    for language, selected in re.findall(r"^CMAKE_(C|CXX)_COMPILER:[^=]+=([^\n]+)$", cache.read_text(), re.MULTILINE):
        path = Path(selected)
        if not path.is_absolute():
            raise ValueError("CMake compiler identity must use an absolute cached path")
        result = checked(output, f"compiler-{stage}-{language}", [path, "--version"])
        metadata = sorted((directory / "CMakeFiles").glob(f"*/CMake{language}Compiler.cmake"))
        compilers[language] = dict(selected_path=str(path), resolved_path=str(path.resolve()), sha256=sha(path),
                                   version=Path(result["stdout"]).read_text().strip(), command=result,
                                   cmake_metadata={str(file): sha(file) for file in metadata})
    if "C" not in compilers:
        raise ValueError(f"Missing CMake C compiler identity: {stage}")
    return dict(compilers=compilers, cmake_cache=dict(path=str(cache), sha256=sha(cache)),
                compile_commands=dict(path=str(commands), sha256=sha(commands)))


def require_artifact_roles(profile: dict) -> dict:
    roles = {}
    for group in ("binaries", "wrappers"):
        if set(profile[group]) != {"pdftoppm", "tesseract"}:
            raise ValueError(f"Incomplete artifact roles: {group}")
        roles.update({group + "." + name: path for name, path in profile[group].items()})
    data = Path(profile["runtime"]["TESSDATA_PREFIX"])
    roles.update(openjpeg=profile["loaded_openjpeg"]["path"], model=str(data / "eng.traineddata"),
                 tsv=str(data / "configs/tsv"), quiet=str(data / "configs/quiet"))
    for role, path in roles.items():
        if path not in profile["artifacts"]:
            raise ValueError(f"Missing required artifact: {role}: {path}")
    return roles


def build(args) -> None:
    require_cpu()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "profile.json").exists():
        raise ValueError("Choose a fresh output; existing profiles are preserved")
    logs = output / ("build-attempt-" + str(time.time_ns()))
    logs.mkdir()
    model = args.traineddata.resolve()
    require_hash(model, MODEL_SHA256)
    sources = output / "sources"
    sources.mkdir(exist_ok=True)
    # Verify every input before extracting or compiling any of them.
    archives = {}
    for name, (version, url, digest) in PINS.items():
        suffix = ".tar.xz" if name == "poppler" else ".tar.gz"
        archive = args.source_cache.resolve() / (name + "-" + version + suffix)
        require_hash(archive, digest)
        archives[name] = archive
    for archive in archives.values():
        with tarfile.open(archive) as tar:
            tar.extractall(sources, filter="data")
    prefix = output / "prefix"
    extra = []
    if args.dependency_prefix:
        dep = args.dependency_prefix.resolve()
        extra = [f"-DCMAKE_INCLUDE_PATH={dep / 'include'}", f"-DCMAKE_LIBRARY_PATH={dep / 'lib/x86_64-linux-gnu'}",
                 f"-DCMAKE_C_FLAGS=-I{dep / 'include/x86_64-linux-gnu'}", f"-DCMAKE_CXX_FLAGS=-I{dep / 'include/x86_64-linux-gnu'}"]
    dep_prefixes = [str(prefix / "openjpeg")] + ([str(args.dependency_prefix.resolve())] if args.dependency_prefix else [])
    configure_common = [args.cmake, "-G", "Ninja", f"-DCMAKE_MAKE_PROGRAM={args.ninja}",
                        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
                        "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-O3 -DNDEBUG", "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O2 -DNDEBUG",
                        "-DCMAKE_PREFIX_PATH=" + ";".join(dep_prefixes), *extra]
    stages = {
        "openjpeg": ["-DBUILD_CODEC=OFF", "-DBUILD_TESTING=OFF", "-DBUILD_SHARED_LIBS=ON", "-DBUILD_STATIC_LIBS=OFF", "-DCMAKE_C_FLAGS=-mfma -ffp-contract=fast"],
        "poppler": ["-DBUILD_SHARED_LIBS=OFF", "-DENABLE_CPP=OFF", "-DENABLE_GLIB=OFF", "-DENABLE_QT5=OFF", "-DENABLE_QT6=OFF",
                    "-DENABLE_BOOST=OFF", "-DENABLE_LIBCURL=OFF", "-DENABLE_NSS3=OFF", "-DENABLE_GPGME=OFF",
                    "-DBUILD_GTK_TESTS=OFF", "-DBUILD_QT5_TESTS=OFF", "-DBUILD_QT6_TESTS=OFF", "-DBUILD_CPP_TESTS=OFF", "-DBUILD_MANUAL_TESTS=OFF"],
        "tesseract": ["-DBUILD_TRAINING_TOOLS=OFF", "-DBUILD_TESTS=OFF", "-DBUILD_SHARED_LIBS=OFF", "-DOPENMP_BUILD=OFF",
                      "-DDISABLE_ARCHIVE=ON", "-DDISABLE_CURL=ON", "-DGRAPHICS_DISABLED=ON", "-DENABLE_NATIVE=OFF",
                      "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-O3 -DNDEBUG"],
    }
    builds, compiler_identities = {}, {}
    for name, options in stages.items():
        source = sources / (name + "-" + PINS[name][0])
        directory = output / "build" / name
        builds[name] = directory
        if name == "poppler":
            settings = output / "poppler-contraction.cmake"
            settings.write_text('set_source_files_properties("${CMAKE_SOURCE_DIR}/poppler/GfxState.cc" PROPERTIES COMPILE_OPTIONS "-mfma;-ffp-contract=fast")\n')
            options += [f"-DCMAKE_PROJECT_INCLUDE={settings}", f"-DOpenJPEG_DIR={prefix / 'openjpeg/lib/openjpeg-2.5'}"]
        checked(logs, "configure-" + name, [*configure_common, "-S", source, "-B", directory, f"-DCMAKE_INSTALL_PREFIX={prefix / name}", *options])
        commands = json.loads((directory / "compile_commands.json").read_text())
        verify_compile_flags(name, commands)
        compiler_identities[name] = collect_compilers(logs, name, directory)
        if name == "poppler":
            gfx = next(item for item in commands if item["file"].endswith("/GfxState.cc"))
            if "-mfma" not in gfx["command"] or "-ffp-contract=fast" not in gfx["command"]:
                raise ValueError("Poppler grayscale contraction flags missing")
        target = "pdftoppm" if name == "poppler" else "tesseract" if name == "tesseract" else "openjp2"
        checked(logs, "build-" + name, [args.cmake, "--build", directory, "--target", target, "--parallel", str(args.jobs)])
        if name == "poppler":
            destination = prefix / "poppler/bin/pdftoppm"
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(directory / "utils/pdftoppm", destination)
        else:
            checked(logs, "install-" + name, [args.cmake, "--install", directory])
    data = prefix / "tessdata"
    (data / "configs").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(model, data / "eng.traineddata")
    for config in ("tsv", "quiet"):
        shutil.copyfile(sources / "tesseract-5.5.2/tessdata/configs" / config, data / "configs" / config)
    library = prefix / "openjpeg/lib/libopenjp2.so.7"
    runtime = {"LD_LIBRARY_PATH": str(library.parent), "TESSDATA_PREFIX": str(data)}
    # Additional dependency prefixes remain explicit in the local build environment.
    if args.dependency_prefix:
        runtime["LD_LIBRARY_PATH"] += ":" + str(args.dependency_prefix.resolve() / "lib/x86_64-linux-gnu")
    binaries = {"pdftoppm": prefix / "poppler/bin/pdftoppm", "tesseract": prefix / "tesseract/bin/tesseract"}
    loaded = loaded_openjpeg(logs, binaries["pdftoppm"], library, os.environ | runtime)
    bindir = output / "bin"
    bindir.mkdir(exist_ok=True)
    for name, executable in binaries.items():
        wrapper(bindir / name, executable, runtime)
    artifacts = [*binaries.values(), library.resolve(), data / "eng.traineddata", data / "configs/tsv", data / "configs/quiet", bindir / "pdftoppm", bindir / "tesseract"]
    versions = [checked(logs, "version-tesseract", [bindir / "tesseract", "--version"]),
                checked(logs, "version-poppler", [bindir / "pdftoppm", "-v"])]
    write_json(output / "profile.json", dict(profile_version=1, mode="live_external_ocr", sources=PINS, model_sha256=MODEL_SHA256,
               cpu="linux-x86_64-avx-fma", runtime=runtime, binaries={k: str(v) for k, v in binaries.items()},
               wrappers={name: str(bindir / name) for name in binaries}, artifacts={str(f): sha(f) for f in artifacts},
               loaded_openjpeg=loaded, versions=versions, compiler_identities=compiler_identities,
               qualification="Build identity only; run gate to qualify actual live behavior"))


def arithmetic_receipt(output: Path, profile_path: Path, profile: dict) -> dict:
    build_root = profile_path.resolve().parent / "build"
    evidence = {}
    for name, binary, symbol in [
        ("poppler-gray", Path(profile["binaries"]["pdftoppm"]), "_ZNK22GfxDeviceRGBColorSpace7getGrayEPK8GfxColorPi"),
        ("openjpeg-mct", Path(profile["loaded_openjpeg"]["path"]), "opj_mct_decode_real"),
        ("openjpeg-dwt", next((build_root / "openjpeg").rglob("dwt.c.o")), None),
    ]:
        command = ["objdump", "-d", *(["--disassemble=" + symbol] if symbol else []), binary]
        result = checked(output, "assembly-" + name, command)
        assembly = Path(result["stdout"]).read_text()
        count = len(re.findall(r"\bv(?:f(?:n?madd|n?msub))\w*\b", assembly))
        if not count:
            raise ValueError(f"Missing generated FMA instructions: {name}")
        evidence[name] = dict(binary=str(binary), binary_sha256=sha(binary), fma_instruction_count=count, disassembly=result)
    return evidence


def gate(args) -> int:
    require_cpu()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    profile = json.loads(args.profile.read_text())
    if profile.get("profile_version") != 1 or profile.get("mode") != "live_external_ocr" or profile.get("sources") != {k: list(v) for k, v in PINS.items()} or profile.get("model_sha256") != MODEL_SHA256:
        raise ValueError("Not the pinned live external-OCR profile")
    require_artifact_roles(profile)
    for file, digest in profile["artifacts"].items():
        require_hash(Path(file), digest)
    require_hash(ROOT / PROBE_PDF, PROBE_PDF_SHA256)
    require_hash(Path(profile["runtime"]["TESSDATA_PREFIX"]) / "eng.traineddata", MODEL_SHA256)
    loaded_openjpeg(output, Path(profile["binaries"]["pdftoppm"]), Path(profile["loaded_openjpeg"]["path"]), os.environ | profile["runtime"])
    loaded = {}
    for name, executable in profile["binaries"].items():
        receipt = checked(output, "dependencies-" + name, ["ldd", executable], env=os.environ | profile["runtime"])
        for line in Path(receipt["stdout"]).read_text().splitlines():
            if "=> /" in line:
                path = Path(line.split("=>", 1)[1].strip().split()[0]).resolve()
                loaded[str(path)] = sha(path)
    elf = checked(output, "renderer-elf", ["readelf", "-d", profile["binaries"]["pdftoppm"]])
    arithmetic = arithmetic_receipt(output, args.profile, profile)
    targets = {**profile["artifacts"], **loaded}
    for file in [args.profile, args.parser.resolve(), args.evaluator.resolve(), Path(__file__), ROOT / "benchmark/eval/corpus/manifest.tsv", ROOT / "benchmark/eval/corpus/metadata.jsonl"]:
        targets[str(file)] = sha(file)
    source_identity = {name: sha(ROOT / name) for name in ("src/adaptive.zig", "src/specialist_protocol.zig", "src/layout.zig", "src/eval_runner.zig")}
    raster = profile["wrappers"]["pdftoppm"]
    ocr = profile["wrappers"]["tesseract"]
    probe = checked(output, "live-raster-probe", [raster, "-q", "-png", "-gray", "-singlefile", "-r", "300", "-f", "1", "-l", "1", "-x", "0", "-y", "0", "-W", "1190", "-H", "1975", ROOT / PROBE_PDF, output / "live-raster"])
    from PIL import Image
    with Image.open(output / "live-raster.png") as image:
        rgb_sha = hashlib.sha256(image.convert("RGB").tobytes()).hexdigest()
        pixel_pass = image.size == (1190, 1975) and rgb_sha == PROBE_RGB_SHA256
    common = ["--ocr-executable", ocr, "--ocr-rasterizer", raster]
    manifest = ROOT / "benchmark/eval/corpus/manifest.tsv"
    metadata = ROOT / "benchmark/eval/corpus/metadata.jsonl"
    checks = [run(output, "live-corpus", [args.evaluator.resolve(), "--adaptive", *common, "--ocr-lang", "eng", "--ocr-dpi", "200", "--ocr-grayscale", "--manifest", manifest, "--metadata", metadata])]
    for label, script, extra in [
        ("form", "ocr_form_quality.py", []),
        ("jbig2", "ocr_hard_document_quality.py", []),
        ("jpx", "ocr_hard_document_quality.py", ["--pdf", PROBE_PDF, "--truth", "benchmark/eval/ground_truth/ocr_text/scanned_typewritten/jpx-public-domain-map-cover.json"]),
    ]:
        checks.append(run(output, "live-semantic-" + label, [sys.executable, ROOT / "benchmark/eval" / script, "--parser", args.parser.resolve(), *common, *extra,
                      "--expected-ocr-version", "tesseract 5.5.2", "--expected-rasterizer-version", "pdftoppm version 26.02.0", "--output", output / (label + ".json")]))
    records = [json.loads(line) for line in Path(checks[0]["stdout"]).read_text().splitlines() if line.startswith("{")]
    evaluated = [r for r in records if "doc_id" in r and "metrics" in r]
    expected_docs = {line.split("\t")[1] for line in manifest.read_text().splitlines() if line and not line.startswith("#")}
    complete = {r["doc_id"] for r in evaluated} == expected_docs and len(evaluated) == len(expected_docs)
    passed = pixel_pass and complete and all(r["exit_code"] == 0 and not r["timed_out"] for r in checks)
    final_hashes = {file: sha(Path(file)) for file in targets}
    unchanged = final_hashes == targets and all(sha(ROOT / name) == digest for name, digest in source_identity.items())
    passed = passed and unchanged
    write_json(output / "report.json", dict(mode="actual_live_pdf_ocr", status="pass" if passed else "fail", profile_sha256=sha(args.profile),
               raster_probe=dict(command=probe, rgb_sha256=rgb_sha, expected_rgb_sha256=PROBE_RGB_SHA256, passed=pixel_pass),
               metadata_sha256=sha(metadata), manifest_sha256=sha(manifest), expected_documents=len(expected_docs), evaluated_documents=len(evaluated),
               corpus_complete=complete, evaluations=evaluated, checks=checks,
               loaded_dependencies=loaded, renderer_elf=elf, arithmetic=arithmetic, source_identity=source_identity,
               initial_artifacts=targets, final_artifacts=final_hashes, artifacts_unchanged=unchanged,
               boundary="Real PDF rasterization and recognition. No stored TSV or PNG is read as input. Stock system tools and other platforms are separate qualifications."))
    return 0 if passed else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="Offline build from checksum-verified release archives")
    b.add_argument("--source-cache", type=Path, required=True)
    b.add_argument("--traineddata", type=Path, required=True)
    b.add_argument("--dependency-prefix", type=Path)
    b.add_argument("--cmake", default=shutil.which("cmake") or "cmake")
    b.add_argument("--ninja", default=shutil.which("ninja") or "ninja")
    b.add_argument("--jobs", type=int, default=2)
    b.add_argument("--output", type=Path, required=True)
    g = sub.add_parser("gate", help="Strict original corpus and independent live semantic gates")
    g.add_argument("--profile", type=Path, required=True)
    g.add_argument("--parser", type=Path, default=ROOT / "zig-out/bin/pdf-parser")
    g.add_argument("--evaluator", type=Path, default=ROOT / "zig-out/bin/pdf-parser-eval")
    g.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        build(args)
        return 0
    return gate(args)


if __name__ == "__main__":
    raise SystemExit(main())
