const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_tesseract_c = b.option(
        bool,
        "tesseract-c",
        "Enable optional libtesseract C API OCR backend",
    ) orelse false;
    const tesseract_include = b.option(
        []const u8,
        "tesseract-include",
        "Directory containing tesseract/capi.h for optional C FFI backend",
    ) orelse "/opt/homebrew/include";
    const tesseract_lib = b.option(
        []const u8,
        "tesseract-lib",
        "Directory containing libtesseract and libleptonica for optional C FFI backend",
    ) orelse "/opt/homebrew/lib";
    const ocr_options = b.addOptions();
    ocr_options.addOption(bool, "enable_tesseract_c", enable_tesseract_c);
    const memory_options = b.addOptions();
    memory_options.addOption(bool, "memcheck", false);
    const tesseract_c = if (enable_tesseract_c) blk: {
        const translated = b.addTranslateC(.{
            .root_source_file = b.path("src/ocr/tesseract_headers.h"),
            .target = target,
            .optimize = optimize,
        });
        translated.addSystemIncludePath(.{ .cwd_relative = tesseract_include });
        translated.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        translated.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
        translated.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        break :blk translated.createModule();
    } else null;
    const ocr_build = OcrBuildOptions{
        .options = ocr_options,
        .memory_options = memory_options,
        .enable_tesseract_c = enable_tesseract_c,
        .tesseract_include = tesseract_include,
        .tesseract_lib = tesseract_lib,
        .tesseract_c = tesseract_c,
    };

    // Main library
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/root.zig", target, optimize, ocr_build),
    });

    b.installArtifact(lib);

    // Shared library for Python/FFI bindings. Exported C symbols keep the
    // zpdf_* prefix for compatibility during the package rename.
    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/capi.zig", target, optimize, ocr_build),
    });

    const install_shared = b.addInstallArtifact(shared_lib, .{});
    b.getInstallStep().dependOn(&install_shared.step);
    const install_header = b.addInstallFile(b.path("include/pdf_parser.h"), "include/pdf_parser.h");
    b.getInstallStep().dependOn(&install_header.step);

    const shared_step = b.step("shared", "Build shared library for FFI");
    shared_step.dependOn(&install_shared.step);
    shared_step.dependOn(&install_header.step);

    // WebAssembly build
    const wasm = b.addExecutable(.{
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/wapi.zig", b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }), .small, ocr_build),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const wasm_step = b.step("wasm", "Build WebAssembly module");
    const install_wasm = b.addInstallArtifact(wasm, .{});
    wasm_step.dependOn(&install_wasm.step);

    // CLI tool
    const exe = b.addExecutable(.{
        .name = "pdf-parser",
        .root_module = parserModule(b, "src/main.zig", target, optimize, ocr_build),
    });

    b.installArtifact(exe);

    // Explicit diagnostic artifacts: ordinary builds keep their allocators.
    const diagnostic_options = b.addOptions();
    diagnostic_options.addOption(bool, "memcheck", true);
    var diagnostic_build = ocr_build;
    diagnostic_build.memory_options = diagnostic_options;
    diagnostic_build.memcheck = true;
    var diagnostic_query = target.query;
    diagnostic_query.cpu_model = .baseline;
    diagnostic_query.cpu_features_add = .empty;
    diagnostic_query.cpu_features_sub = .empty;
    const diagnostic_target = b.resolveTargetQuery(diagnostic_query);
    const diagnostic_exe = b.addExecutable(.{
        .name = "pdf-parser",
        .root_module = parserModule(b, "src/main.zig", diagnostic_target, .debug, diagnostic_build),
        .use_llvm = true,
    });
    const diagnostic_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pdf_parser",
        .root_module = parserModule(b, "src/capi.zig", diagnostic_target, .debug, diagnostic_build),
        .use_llvm = true,
    });
    const memcheck_build_step = b.step("memcheck-build", "Build isolated libc-backed Memcheck artifacts");
    const diagnostic_info = b.addWriteFiles();
    const target_triple = diagnostic_target.result.zigTriple(b.allocator) catch @panic("out of memory");
    const info_file = diagnostic_info.add("memcheck-build.json", b.fmt(
        "{{\"zig_version\":\"{s}\",\"allocator\":\"libc\",\"allocation_counters\":true,\"optimize\":\"debug\",\"cpu\":\"baseline\",\"target\":\"{s}\",\"compiler_valgrind\":{},\"tesseract_c\":{},\"stdio\":\"{s}\",\"zig_error_return_tracing\":{}}}\n",
        .{ @import("builtin").zig_version_string, target_triple, switch (diagnostic_target.result.cpu.arch) {
            .x86, .x86_64 => true,
            else => false,
        }, enable_tesseract_c, if (diagnostic_target.result.os.tag == .macos) "streaming" else "default", diagnostic_target.result.os.tag != .macos },
    ));
    memcheck_build_step.dependOn(&b.addInstallFile(info_file, "memcheck/build-info.json").step);
    for ([_]*std.Build.Step.Compile{ diagnostic_exe, diagnostic_lib }) |artifact| {
        const directory = if (artifact == diagnostic_exe) "memcheck/bin" else "memcheck/lib";
        const install = b.addInstallArtifact(artifact, .{
            .dest_dir = .{ .override = .{ .custom = directory } },
        });
        memcheck_build_step.dependOn(&install.step);
    }
    const arena_probe = b.addExecutable(.{
        .name = "memcheck-arena",
        .root_module = parserModule(b, "src/memcheck_arena.zig", diagnostic_target, .debug, diagnostic_build),
        .use_llvm = true,
    });
    memcheck_build_step.dependOn(&b.addInstallArtifact(arena_probe, .{
        .dest_dir = .{ .override = .{ .custom = "memcheck/bin" } },
    }).step);
    const counter_probe = b.addExecutable(.{
        .name = "memcheck-allocator-probe",
        .root_module = parserModule(b, "src/memcheck_allocator_probe.zig", diagnostic_target, .debug, diagnostic_build),
        .use_llvm = true,
    });
    memcheck_build_step.dependOn(&b.addInstallArtifact(counter_probe, .{
        .dest_dir = .{ .override = .{ .custom = "memcheck/bin" } },
    }).step);
    if (enable_tesseract_c) {
        const diagnostic_ocr = b.addExecutable(.{
            .name = "memcheck-ocr",
            .root_module = parserModule(b, "src/memcheck_ocr.zig", diagnostic_target, .debug, diagnostic_build),
            .use_llvm = true,
        });
        memcheck_build_step.dependOn(&b.addInstallArtifact(diagnostic_ocr, .{
            .dest_dir = .{ .override = .{ .custom = "memcheck/bin" } },
        }).step);
    }

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the pdf-parser CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const lib_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/root.zig", target, optimize, ocr_build),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const simd_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/simd.zig", target, optimize, ocr_build),
    });

    const run_simd_unit_tests = b.addRunArtifact(simd_unit_tests);

    const decompress_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/decompress.zig", target, optimize, ocr_build),
    });

    const run_decompress_unit_tests = b.addRunArtifact(decompress_unit_tests);

    const parser_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/parser.zig", target, optimize, ocr_build),
    });

    const run_parser_unit_tests = b.addRunArtifact(parser_unit_tests);

    const xref_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/xref.zig", target, optimize, ocr_build),
    });

    const run_xref_unit_tests = b.addRunArtifact(xref_unit_tests);

    const encoding_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/encoding.zig", target, optimize, ocr_build),
    });

    const run_encoding_unit_tests = b.addRunArtifact(encoding_unit_tests);

    const runtime_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/runtime.zig", target, optimize, ocr_build),
    });

    const run_runtime_unit_tests = b.addRunArtifact(runtime_unit_tests);

    const layout_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/layout.zig", target, optimize, ocr_build),
    });

    const run_layout_unit_tests = b.addRunArtifact(layout_unit_tests);

    const native_layout_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/native_layout.zig", target, optimize, ocr_build),
    });

    const run_native_layout_unit_tests = b.addRunArtifact(native_layout_unit_tests);

    const text_search_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/text_search.zig", target, optimize, ocr_build),
    });

    const run_text_search_unit_tests = b.addRunArtifact(text_search_unit_tests);

    const complexity_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/complexity.zig", target, optimize, ocr_build),
    });

    const run_complexity_unit_tests = b.addRunArtifact(complexity_unit_tests);

    const specialists_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/specialists.zig", target, optimize, ocr_build),
    });

    const run_specialists_unit_tests = b.addRunArtifact(specialists_unit_tests);

    const specialist_protocol_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/specialist_protocol.zig", target, optimize, ocr_build),
    });

    const run_specialist_protocol_unit_tests = b.addRunArtifact(specialist_protocol_unit_tests);

    const reconcile_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/reconcile.zig", target, optimize, ocr_build),
    });

    const run_reconcile_unit_tests = b.addRunArtifact(reconcile_unit_tests);

    const schema_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/schema.zig", target, optimize, ocr_build),
    });

    const run_schema_unit_tests = b.addRunArtifact(schema_unit_tests);

    const stream_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/stream.zig", target, optimize, ocr_build),
    });

    const run_stream_unit_tests = b.addRunArtifact(stream_unit_tests);

    const adaptive_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/adaptive.zig", target, optimize, ocr_build),
    });

    const run_adaptive_unit_tests = b.addRunArtifact(adaptive_unit_tests);

    const main_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/main.zig", target, optimize, ocr_build),
    });

    const run_main_unit_tests = b.addRunArtifact(main_unit_tests);

    const capi_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/capi.zig", target, optimize, ocr_build),
    });
    const public_header = b.addTranslateC(.{
        .root_source_file = b.path("include/pdf_parser.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    capi_unit_tests.root_module.addImport("pdf_parser_c", public_header.createModule());

    const run_capi_unit_tests = b.addRunArtifact(capi_unit_tests);

    const eval_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/eval.zig", target, optimize, ocr_build),
    });

    const run_eval_unit_tests = b.addRunArtifact(eval_unit_tests);

    const eval_runner_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/eval_runner.zig", target, optimize, ocr_build),
    });

    const run_eval_runner_unit_tests = b.addRunArtifact(eval_runner_unit_tests);

    const benchmark_runner_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/benchmark_runner.zig", target, optimize, ocr_build),
    });

    const run_benchmark_runner_unit_tests = b.addRunArtifact(benchmark_runner_unit_tests);

    const server_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/server.zig", target, optimize, ocr_build),
    });

    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    const ocr_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/ocr.zig", target, optimize, ocr_build),
    });

    const run_ocr_unit_tests = b.addRunArtifact(ocr_unit_tests);

    const ocr_step = b.step("ocr-test", "Run OCR adapter unit tests");
    ocr_step.dependOn(&run_ocr_unit_tests.step);

    if (enable_tesseract_c) {
        const tesseract_c_unit_tests = b.addTest(.{
            .root_module = parserModule(b, "src/ocr.zig", target, optimize, ocr_build),
        });
        const run_tesseract_c_unit_tests = b.addRunArtifact(tesseract_c_unit_tests);
        ocr_step.dependOn(&run_tesseract_c_unit_tests.step);

        const tesseract_c_ffi_unit_tests = b.addTest(.{
            .root_module = parserModule(b, "src/ocr/tesseract_c_ffi.zig", target, optimize, ocr_build),
        });
        const run_tesseract_c_ffi_unit_tests = b.addRunArtifact(tesseract_c_ffi_unit_tests);
        ocr_step.dependOn(&run_tesseract_c_ffi_unit_tests.step);
    }

    const interpreter_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/interpreter.zig", target, optimize, ocr_build),
    });

    const run_interpreter_unit_tests = b.addRunArtifact(interpreter_unit_tests);

    const testpdf_unit_tests = b.addTest(.{
        .root_module = parserModule(b, "src/testpdf.zig", target, optimize, ocr_build),
    });

    const run_testpdf_unit_tests = b.addRunArtifact(testpdf_unit_tests);

    const integration_tests = b.addTest(.{
        .root_module = parserModule(b, "src/integration_test.zig", target, optimize, ocr_build),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const native_eval_tests = b.addTest(.{
        .root_module = parserModule(b, "src/native_eval.zig", target, optimize, ocr_build),
    });

    const run_native_eval_tests = b.addRunArtifact(native_eval_tests);

    const native_eval_step = b.step("native-eval", "Run native extraction correctness fixtures");
    native_eval_step.dependOn(&run_native_eval_tests.step);

    const eval_corpus_exe = b.addExecutable(.{
        .name = "pdf-parser-eval-corpus",
        .root_module = parserModule(b, "src/eval_corpus_writer.zig", target, optimize, ocr_build),
    });
    const eval_corpus_cmd = b.addRunArtifact(eval_corpus_exe);
    eval_corpus_cmd.addPassthruArgs();

    const eval_corpus_step = b.step("eval-corpus", "Generate tiny evaluation corpus fixtures");
    eval_corpus_step.dependOn(&eval_corpus_cmd.step);

    const eval_exe = b.addExecutable(.{
        .name = "pdf-parser-eval",
        .root_module = parserModule(b, "src/eval_runner.zig", target, optimize, ocr_build),
    });
    b.installArtifact(eval_exe);

    const eval_cmd = b.addRunArtifact(eval_exe);
    eval_cmd.step.dependOn(b.getInstallStep());
    eval_cmd.addPassthruArgs();

    const eval_step = b.step("eval", "Run per-document evaluation and emit JSONL");
    eval_step.dependOn(&eval_cmd.step);

    const benchmark_eval_cmd = b.addRunArtifact(exe);
    benchmark_eval_cmd.step.dependOn(b.getInstallStep());
    benchmark_eval_cmd.addArgs(&.{
        "benchmark",
        "--manifest",
        "benchmark/eval/corpus/manifest.tsv",
        "--suite-id",
        "tiny-corpus",
        "--tools",
        "pdf-parser:native",
    });
    benchmark_eval_cmd.addPassthruArgs();

    const benchmark_eval_step = b.step("benchmark-eval", "Run corpus benchmark scorecard");
    benchmark_eval_step.dependOn(&benchmark_eval_cmd.step);

    const benchmark_quality_cmd = b.addRunArtifact(exe);
    benchmark_quality_cmd.step.dependOn(b.getInstallStep());
    benchmark_quality_cmd.addArgs(&.{
        "benchmark",
        "--manifest",
        "benchmark/eval/gates/born-digital.tsv",
        "--suite-id",
        "born-digital-gate",
        "--tools",
        "pdf-parser:native",
        "--thresholds",
        "benchmark/eval/gates/born-digital-thresholds.json",
        "--fail-on-regression",
        "--fail-on-skipped",
    });
    benchmark_eval_step.dependOn(&benchmark_quality_cmd.step);

    const benchmark_font_quality_cmd = b.addRunArtifact(exe);
    benchmark_font_quality_cmd.step.dependOn(b.getInstallStep());
    benchmark_font_quality_cmd.addArgs(&.{
        "benchmark",
        "--manifest",
        "benchmark/eval/gates/hard-fonts.tsv",
        "--suite-id",
        "hard-font-gate",
        "--tools",
        "pdf-parser:native",
        "--thresholds",
        "benchmark/eval/gates/hard-fonts-thresholds.json",
        "--fail-on-regression",
        "--fail-on-skipped",
    });
    benchmark_eval_step.dependOn(&benchmark_font_quality_cmd.step);

    // Native decoding and adaptive reconstruction are separate quality lanes.
    // Both must satisfy the same text floors before public artifacts qualify.
    const benchmark_adaptive_quality_cmd = b.addRunArtifact(exe);
    benchmark_adaptive_quality_cmd.step.dependOn(b.getInstallStep());
    benchmark_adaptive_quality_cmd.addArgs(&.{
        "benchmark",            "--manifest",                 "benchmark/eval/gates/born-digital.tsv",
        "--suite-id",           "adaptive-born-digital-gate", "--tools",
        "pdf-parser:adaptive",  "--thresholds",               "benchmark/eval/gates/born-digital-thresholds.json",
        "--fail-on-regression", "--fail-on-skipped",
    });
    benchmark_eval_step.dependOn(&benchmark_adaptive_quality_cmd.step);

    const benchmark_adaptive_font_quality_cmd = b.addRunArtifact(exe);
    benchmark_adaptive_font_quality_cmd.step.dependOn(b.getInstallStep());
    benchmark_adaptive_font_quality_cmd.addArgs(&.{
        "benchmark",            "--manifest",              "benchmark/eval/gates/hard-fonts.tsv",
        "--suite-id",           "adaptive-hard-font-gate", "--tools",
        "pdf-parser:adaptive",  "--thresholds",            "benchmark/eval/gates/hard-fonts-thresholds.json",
        "--fail-on-regression", "--fail-on-skipped",
    });
    benchmark_eval_step.dependOn(&benchmark_adaptive_font_quality_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_simd_unit_tests.step);
    test_step.dependOn(&run_decompress_unit_tests.step);
    test_step.dependOn(&run_parser_unit_tests.step);
    test_step.dependOn(&run_xref_unit_tests.step);
    test_step.dependOn(&run_encoding_unit_tests.step);
    test_step.dependOn(&run_runtime_unit_tests.step);
    test_step.dependOn(&run_layout_unit_tests.step);
    test_step.dependOn(&run_native_layout_unit_tests.step);
    test_step.dependOn(&run_text_search_unit_tests.step);
    test_step.dependOn(&run_complexity_unit_tests.step);
    test_step.dependOn(&run_specialists_unit_tests.step);
    test_step.dependOn(&run_specialist_protocol_unit_tests.step);
    test_step.dependOn(&run_reconcile_unit_tests.step);
    test_step.dependOn(&run_schema_unit_tests.step);
    test_step.dependOn(&run_stream_unit_tests.step);
    test_step.dependOn(&run_adaptive_unit_tests.step);
    test_step.dependOn(&run_main_unit_tests.step);
    test_step.dependOn(&run_capi_unit_tests.step);
    test_step.dependOn(&run_eval_unit_tests.step);
    test_step.dependOn(&run_eval_runner_unit_tests.step);
    test_step.dependOn(&run_benchmark_runner_unit_tests.step);
    test_step.dependOn(&run_server_unit_tests.step);
    test_step.dependOn(&run_ocr_unit_tests.step);
    test_step.dependOn(&run_interpreter_unit_tests.step);
    test_step.dependOn(&run_testpdf_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_native_eval_tests.step);

    // Benchmark
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = parserModule(b, "src/bench.zig", target, .fast, ocr_build),
    });

    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());

    bench_cmd.addPassthruArgs();

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Narrow in-process scanner benchmark. Unlike the document benchmark above,
    // this keeps allocation, subprocesses, and I/O outside the timed region.
    const simd_bench = b.addExecutable(.{
        .name = "simd-bench",
        .root_module = parserModule(b, "src/simd_bench.zig", target, optimize, ocr_build),
    });
    const simd_bench_cmd = b.addRunArtifact(simd_bench);
    simd_bench_cmd.addPassthruArgs();

    const simd_bench_step = b.step("simd-bench", "Benchmark scalar, std, and existing SIMD substring search");
    simd_bench_step.dependOn(&simd_bench_cmd.step);

    const simd_bench_tests = b.addTest(.{
        .root_module = parserModule(b, "src/simd_bench.zig", target, optimize, ocr_build),
    });
    test_step.dependOn(&b.addRunArtifact(simd_bench_tests).step);
}

const OcrBuildOptions = struct {
    options: *std.Build.Step.Options,
    memory_options: *std.Build.Step.Options,
    memcheck: bool = false,
    enable_tesseract_c: bool,
    tesseract_include: []const u8,
    tesseract_lib: []const u8,
    tesseract_c: ?*std.Build.Module,
};

fn parserModule(
    b: *std.Build,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    ocr_build: OcrBuildOptions,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    module.addSystemIncludePath(.{ .cwd_relative = "include" });
    module.addOptions("ocr_options", ocr_build.options);
    module.addOptions("memory_options", ocr_build.memory_options);
    if (ocr_build.memcheck) {
        module.link_libc = true;
        module.strip = false;
        module.omit_frame_pointer = false;
        module.unwind_tables = .sync;
        // macOS error-return stack printing reads debug data through preadv,
        // which the fork does not handle. Keep symbols and Memcheck stacks;
        // disabling Zig error-return traces does not disable runtime safety.
        if (target.result.os.tag == .macos) module.error_tracing = false;
        // Zig 0.17 rejects -fvalgrind on ARM64. The macOS fork still
        // instruments libc allocations; compiler client requests are separate.
        module.valgrind = switch (target.result.cpu.arch) {
            .x86, .x86_64 => true,
            else => false,
        };
    }

    if (ocr_build.enable_tesseract_c) {
        module.addImport("tesseract_c", ocr_build.tesseract_c.?);
        module.link_libc = true;
        module.addSystemIncludePath(.{ .cwd_relative = ocr_build.tesseract_include });
        module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        module.addSystemIncludePath(.{ .cwd_relative = "/usr/local/include" });
        module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        module.addLibraryPath(.{ .cwd_relative = ocr_build.tesseract_lib });
        module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        // Diagnostic builds select the dependency explicitly. pkg-config can
        // inject a different installation or duplicate its include path.
        module.linkSystemLibrary("tesseract", .{ .use_pkg_config = if (ocr_build.memcheck) .no else .yes });
        module.linkSystemLibrary("leptonica", .{});
    }

    return module;
}
