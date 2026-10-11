//! pdf-parser - Zero-copy PDF Parser
//!
//! High-performance native extraction kernel for an adaptive PDF parser.
//!
//! Key design principles:
//! 1. Memory-mapped, zero-copy where possible
//! 2. Lazy parsing - only decode what's accessed
//! 3. SIMD-accelerated lexing for structural parsing
//! 4. Streaming extraction - no intermediate fz_stext_page equivalent
//! 5. Explicit error budgets - caller controls tolerance

const std = @import("std");
const form_scope = @import("form_scope.zig");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const native_os = builtin.target.os.tag;

const is_wasm = builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64;
const is_windows = native_os == .windows;

// Internal modules
pub const parser = @import("parser.zig");
pub const xref = @import("xref.zig");
pub const pagetree = @import("pagetree.zig");
pub const encoding = @import("encoding.zig");
pub const interpreter = @import("interpreter.zig");
pub const decompress = @import("decompress.zig");
pub const encryption = @import("encryption.zig");
pub const structural = @import("structural.zig");
pub const simd = @import("simd.zig");
pub const layout = @import("layout.zig");
pub const page_geometry = @import("page_geometry.zig");
pub const vector_evidence = @import("vector_evidence.zig");
pub const native_layout = @import("native_layout.zig");
pub const text_search = @import("text_search.zig");
pub const structtree = @import("structtree.zig");
pub const markdown = @import("markdown.zig");
pub const outline = @import("outline.zig");
pub const complexity = @import("complexity.zig");
pub const ocr = @import("ocr.zig");
pub const specialists = @import("specialists.zig");
pub const specialist_protocol = @import("specialist_protocol.zig");
pub const reconcile = @import("reconcile.zig");
pub const adaptive = @import("adaptive.zig");
pub const schema = @import("schema.zig");
pub const stream = @import("stream.zig");
pub const adapter = @import("adapter.zig");
pub const visual_assets = @import("visual_assets.zig");
pub const eval = @import("eval.zig");
pub const extraction_diagnostics = @import("extraction_diagnostics.zig");

// Re-exports
pub const Object = parser.Object;
pub const ObjRef = parser.ObjRef;
pub const XRefTable = xref.XRefTable;
pub const Page = pagetree.Page;
pub const FontEncoding = encoding.FontEncoding;
pub const TextSpan = layout.TextSpan;
pub const GlyphSpan = interpreter.GlyphSpan;
pub const NativeLayoutResult = native_layout.Result;
pub const NativeLayoutQuality = native_layout.QualityMetrics;
pub const SearchTextOptions = text_search.Options;
pub const SearchSourceKind = text_search.SourceKind;
pub const LineRole = layout.LineRole;
pub const BlockKind = layout.BlockKind;
pub const CandidateKind = layout.CandidateKind;
pub const LayoutBlock = layout.LayoutBlock;
pub const LayoutCandidate = layout.LayoutCandidate;
pub const LayoutResult = layout.LayoutResult;
pub const PageComplexity = complexity.PageScore;
pub const RegionComplexity = complexity.RegionScore;
pub const RulingLine = specialists.RulingLine;
pub const RulingOrientation = specialists.RulingOrientation;
pub const TableScore = specialists.TableScore;
pub const FormulaScore = specialists.FormulaScore;
pub const TableSpecialistKind = specialists.TableSpecialistKind;
pub const FormulaSpecialistKind = specialists.FormulaSpecialistKind;
pub const SpecialistConfig = specialists.SpecialistConfig;
pub const SpecialistOutput = specialists.SpecialistOutput;
pub const SpecialistKind = specialist_protocol.SpecialistKind;
pub const SpecialistProtocolConfig = specialist_protocol.SpecialistConfig;
pub const SpecialistProtocolConfigEntry = specialist_protocol.SpecialistConfigEntry;
pub const SpanLayer = reconcile.SpanLayer;
pub const ReconcileOptions = reconcile.ReconcileOptions;
pub const ReconciledDocument = reconcile.ReconciledDocument;
pub const ReconciledSpan = reconcile.ReconciledSpan;
pub const ReconciledBlock = reconcile.ReconciledBlock;
pub const RagChunk = reconcile.RagChunk;
pub const AdaptiveOptions = adaptive.ExtractOptions;
pub const AdaptiveResult = adaptive.Result;
pub const AdaptivePageRoute = adaptive.PageRoute;
pub const AdaptiveRegionRoute = adaptive.RegionRoute;
pub const AdaptiveTraceRecord = adaptive.TraceRecord;
pub const AdaptiveLayoutBlock = adaptive.LayoutBlockSummary;
pub const AdaptiveOutputFormat = adaptive.OutputFormat;
pub const StreamingOptions = stream.StreamingOptions;
pub const StreamingSummary = stream.StreamingSummary;
pub const StreamingEventType = stream.StreamingEventType;
pub const AdaptiveAdapterOptions = adapter.AdaptiveAdapterOptions;
pub const AdaptiveAdapterFormat = adapter.AdaptiveAdapterFormat;
pub const AdaptiveAdapterSummary = adapter.AdaptiveAdapterSummary;
pub const VisualAssetRecord = visual_assets.AssetRecord;
pub const CorpusCategory = eval.CorpusCategory;
pub const TextMetrics = eval.TextMetrics;
pub const DocumentResult = eval.DocumentResult;
pub const OcrConfig = ocr.OcrConfig;
pub const OcrInput = ocr.OcrInput;
pub const OcrBackend = ocr.Backend;
pub const OcrPolicy = ocr.Policy;
pub const OcrPageSegMode = ocr.PageSegMode;
pub const StructTree = structtree.StructTree;
pub const StructElement = structtree.StructElement;
pub const MarkdownOptions = markdown.MarkdownOptions;
pub const MarkdownRenderer = markdown.MarkdownRenderer;
pub const FullTextMode = enum { accuracy, raw_recall, fast };
pub const EncryptionInfo = encryption.Info;
pub const EncryptionAuthType = encryption.AuthType;
pub const EncryptionCryptMethod = encryption.CryptMethod;
pub const EncryptionPermissions = encryption.Permissions;
pub const StructuralDiagnostic = structural.Diagnostic;
pub const StructuralSummary = structural.Summary;
pub const ExtractionDiagnostics = extraction_diagnostics.Report;

pub const NativePageGeometry = struct {
    allocator: std.mem.Allocator,
    spans: []TextSpan,
    glyphs: []GlyphSpan,
    // Authoritative semantic projection, when marked content replaces glyph
    // text. Raw glyphs remain available for diagnostic evidence.
    semantic_glyphs: ?[]GlyphSpan = null,

    pub fn deinit(self: *NativePageGeometry) void {
        Document.freeTextSpans(self.allocator, self.spans);
        Document.freeGlyphSpans(self.allocator, self.glyphs);
        if (self.semantic_glyphs) |glyphs| Document.freeGlyphSpans(self.allocator, glyphs);
    }
};

/// Error handling configuration
pub const ErrorConfig = struct {
    /// Maximum errors before aborting
    max_errors: u32 = 100,
    /// Continue on parse errors?
    continue_on_parse_error: bool = true,
    /// Continue on missing objects?
    continue_on_missing_object: bool = true,
    /// Continue on encoding errors?
    continue_on_encoding_error: bool = true,
    /// Log errors to stderr?
    log_errors: bool = false,
    /// Optional password for encrypted PDFs.
    password: ?[]const u8 = null,
    /// Try the empty password path when no password is supplied.
    allow_empty_password: bool = true,
    /// Record permissions by default, but do not block extraction.
    respect_permissions: bool = false,
    /// Allow reading weak legacy encryption such as RC4-40/128.
    allow_weak_crypto: bool = true,

    pub fn default() ErrorConfig {
        return .{};
    }

    pub fn strict() ErrorConfig {
        return .{
            .max_errors = 0,
            .continue_on_parse_error = false,
            .continue_on_missing_object = false,
            .continue_on_encoding_error = false,
            .allow_empty_password = true,
        };
    }

    pub fn permissive() ErrorConfig {
        return .{
            .max_errors = std.math.maxInt(u32),
            .continue_on_parse_error = true,
            .continue_on_missing_object = true,
            .continue_on_encoding_error = true,
        };
    }
};

/// Parse error record
pub const ParseErrorRecord = struct {
    kind: Kind,
    offset: u64,
    message: []const u8,

    pub const Kind = enum {
        invalid_header,
        invalid_xref,
        missing_object,
        invalid_stream,
        encoding_error,
        syntax_error,
        encrypted,
    };
};

/// PDF Document
pub const Document = struct {
    /// Memory-mapped file data (zero-copy base)
    data: []const u8,
    /// Whether we own the data (mmap'd or allocated)
    owns_data: bool,
    /// Whether data was allocated (Windows) vs mmap'd (POSIX)
    data_is_allocated: bool = false,

    /// Original filesystem path when opened from a file. Subprocess OCR
    /// rasterizers need a path; memory-opened documents leave this null.
    source_path: ?[]const u8 = null,

    /// Cross-reference table
    xref_table: XRefTable,

    /// Page array (flattened from tree)
    pages: std.ArrayList(Page),

    /// Object resolution cache
    object_cache: std.AutoHashMap(u32, Object),

    /// Allocator for long-lived allocations
    allocator: std.mem.Allocator,

    /// Arena for parsed objects (freed on close)
    parsing_arena: std.heap.ArenaAllocator,

    /// Error configuration
    error_config: ErrorConfig,

    /// PDF Standard Security Handler, present after successful authentication.
    security: ?encryption.SecurityHandler = null,

    /// Accumulated errors
    errors: std.ArrayList(ParseErrorRecord),

    /// Structural parser diagnostics with recovery evidence.
    structural_diagnostics: std.ArrayList(structural.Diagnostic),

    /// Pre-resolved font encodings (key: "pageNum:fontName")
    font_cache: std.StringHashMap(encoding.FontEncoding),

    /// Font encoding cache by object ID (avoids re-parsing same font object)
    font_obj_cache: std.AutoHashMap(u32, encoding.FontEncoding),

    /// Cached structure tree reading order (parsed lazily)
    /// Key: page index, Value: list of MCIDs in reading order
    cached_reading_order: ?std.AutoHashMap(usize, std.ArrayList(structtree.MarkedContentRef)) = null,
    reading_order_parsed: bool = false,

    /// Open a PDF file (not available on WASM)
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !*Document {
        return openWithConfig(allocator, path, ErrorConfig.default());
    }

    /// Open a PDF file with custom error configuration (not available on WASM)
    pub fn openWithConfig(allocator: std.mem.Allocator, path: []const u8, config: ErrorConfig) !*Document {
        if (comptime is_wasm) {
            @compileError("File I/O is not available on WASM. Use openFromMemory instead.");
        }

        if (comptime is_windows) {
            const data = try runtime.readFileAllocAlignedCwd(
                allocator,
                path,
                .fromByteUnits(std.heap.page_size_min),
            );
            const doc = try openFromMemoryOwnedAlloc(allocator, data, config);
            errdefer doc.close();
            doc.source_path = try allocator.dupe(u8, path);
            return doc;
        } else {
            const data = try runtime.mmapFileReadOnlyCwd(allocator, path);
            const doc = try openFromMemoryOwned(allocator, data, config);
            errdefer doc.close();
            doc.source_path = try allocator.dupe(u8, path);
            return doc;
        }
    }

    /// Open from owned memory (will be freed on close via munmap)
    fn openFromMemoryOwned(allocator: std.mem.Allocator, data: []align(std.heap.page_size_min) u8, config: ErrorConfig) !*Document {
        if (comptime is_wasm) {
            @compileError("openFromMemoryOwned is not available on WASM. Use openFromMemory instead.");
        }

        const doc = allocator.create(Document) catch |err| {
            if (comptime !is_windows) std.posix.munmap(data);
            return err;
        };

        doc.* = .{
            .data = data,
            .owns_data = true,
            .data_is_allocated = false,
            .source_path = null,
            .xref_table = XRefTable.init(allocator),
            .pages = .empty,
            .object_cache = std.AutoHashMap(u32, Object).init(allocator),
            .allocator = allocator,
            .parsing_arena = std.heap.ArenaAllocator.init(allocator),
            .error_config = config,
            .security = null,
            .errors = .empty,
            .structural_diagnostics = .empty,
            .font_cache = std.StringHashMap(encoding.FontEncoding).init(allocator),
            .font_obj_cache = std.AutoHashMap(u32, encoding.FontEncoding).init(allocator),
        };

        errdefer doc.close();
        try doc.parseDocument();
        return doc;
    }

    /// Open from owned allocated memory (Windows - will be freed on close via allocator.free)
    fn openFromMemoryOwnedAlloc(allocator: std.mem.Allocator, data: []align(std.heap.page_size_min) u8, config: ErrorConfig) !*Document {
        const doc = allocator.create(Document) catch |err| {
            allocator.free(data);
            return err;
        };

        doc.* = .{
            .data = data,
            .owns_data = true,
            .data_is_allocated = true,
            .source_path = null,
            .xref_table = XRefTable.init(allocator),
            .pages = .empty,
            .object_cache = std.AutoHashMap(u32, Object).init(allocator),
            .allocator = allocator,
            .parsing_arena = std.heap.ArenaAllocator.init(allocator),
            .error_config = config,
            .security = null,
            .errors = .empty,
            .structural_diagnostics = .empty,
            .font_cache = std.StringHashMap(encoding.FontEncoding).init(allocator),
            .font_obj_cache = std.AutoHashMap(u32, encoding.FontEncoding).init(allocator),
        };

        errdefer doc.close();
        try doc.parseDocument();
        return doc;
    }

    /// Open a PDF from caller-owned memory without copying.
    /// Caller must keep the memory alive until close().
    pub fn openFromMemoryUnsafe(allocator: std.mem.Allocator, data: []const u8, config: ErrorConfig) !*Document {
        const doc = try allocator.create(Document);

        doc.* = .{
            .data = data,
            .owns_data = false,
            .data_is_allocated = false,
            .source_path = null,
            .xref_table = XRefTable.init(allocator),
            .pages = .empty,
            .object_cache = std.AutoHashMap(u32, Object).init(allocator),
            .allocator = allocator,
            .parsing_arena = std.heap.ArenaAllocator.init(allocator),
            .error_config = config,
            .security = null,
            .errors = .empty,
            .structural_diagnostics = .empty,
            .font_cache = std.StringHashMap(encoding.FontEncoding).init(allocator),
            .font_obj_cache = std.AutoHashMap(u32, encoding.FontEncoding).init(allocator),
        };

        errdefer doc.close();
        try doc.parseDocument();
        return doc;
    }

    /// Backward-compatible alias of openFromMemoryUnsafe.
    pub fn openFromMemory(allocator: std.mem.Allocator, data: []const u8, config: ErrorConfig) !*Document {
        return openFromMemoryUnsafe(allocator, data, config);
    }

    fn parseDocument(self: *Document) !void {
        const arena = self.parsing_arena.allocator();

        // Verify header
        if (!std.mem.startsWith(u8, self.data, "%PDF-")) {
            if (!self.error_config.continue_on_parse_error) {
                return error.InvalidPdfHeader;
            }
            try self.structural_diagnostics.append(self.allocator, .{
                .code = .invalid_header,
                .severity = .warning,
                .stage = .header,
                .offset = 0,
                .action = .recovered,
                .message = "Invalid PDF header",
            });
            try self.errors.append(self.allocator, .{
                .kind = .invalid_header,
                .offset = 0,
                .message = "Invalid PDF header",
            });
        }

        // Parse XRef (HashMap uses base allocator, parsed objects use arena)
        self.xref_table = xref.parseXRefWithOptions(self.allocator, arena, self.data, .{
            .recover = true,
            .diagnostics = &self.structural_diagnostics,
            .diagnostic_allocator = self.allocator,
        }) catch |err| {
            if (self.error_config.continue_on_parse_error) {
                try self.errors.append(self.allocator, .{
                    .kind = .invalid_xref,
                    .offset = 0,
                    .message = "Failed to parse XRef table",
                });
                return;
            } else {
                return err;
            }
        };

        try self.authenticateIfEncrypted(arena);

        // Build page tree (uses arena for all allocations)
        const pages_slice = pagetree.buildPageTreeWithOptions(arena, self.data, &self.xref_table, .{
            .security = self.securityHandler(),
            .diagnostics = &self.structural_diagnostics,
            .diagnostic_allocator = self.allocator,
            .recover = self.error_config.continue_on_parse_error,
        }) catch |err| {
            if (self.error_config.continue_on_parse_error) {
                try self.errors.append(self.allocator, .{
                    .kind = .syntax_error,
                    .offset = 0,
                    .message = "Failed to build page tree",
                });
                return;
            } else {
                return err;
            }
        };

        // Move pages to ArrayList (arena allocated slice, no need to free)
        for (pages_slice) |page| {
            try self.pages.append(self.allocator, page);
        }
    }

    fn authenticateIfEncrypted(self: *Document, arena: std.mem.Allocator) !void {
        const encrypt_obj = self.xref_table.trailer.get("Encrypt") orelse return;
        const encrypt_ref: ?ObjRef = switch (encrypt_obj) {
            .reference => |r| r,
            else => null,
        };
        const resolved = switch (encrypt_obj) {
            .reference => |r| pagetree.resolveRef(arena, self.data, &self.xref_table, r, &self.object_cache) catch encrypt_obj,
            else => encrypt_obj,
        };
        const encrypt_dict = switch (resolved) {
            .dict => |d| d,
            else => {
                if (!self.error_config.continue_on_parse_error) return error.InvalidEncryptionDictionary;
                try self.errors.append(self.allocator, .{
                    .kind = .encrypted,
                    .offset = 0,
                    .message = "PDF encryption dictionary is malformed",
                });
                return;
            },
        };

        const security = encryption.parseAndAuthenticate(
            arena,
            encrypt_ref,
            encrypt_dict,
            self.xref_table.trailer,
            self.error_config.password,
            self.error_config.allow_empty_password,
        ) catch |err| {
            if (!self.error_config.continue_on_parse_error) return err;
            try self.errors.append(self.allocator, .{
                .kind = .encrypted,
                .offset = 0,
                .message = switch (err) {
                    error.InvalidPassword => "PDF is encrypted and requires a valid password",
                    error.UnsupportedSecurityHandler => "PDF uses an unsupported encryption security handler",
                    error.UnsupportedCryptFilter => "PDF uses an unsupported encryption crypt filter",
                    error.UnsupportedRevision => "PDF uses an unsupported encryption revision",
                    error.UnsupportedVersion => "PDF uses an unsupported encryption version",
                    error.WeakCryptoDisabled => "PDF uses weak encryption and weak crypto reading is disabled",
                    error.PermissionDenied => "PDF permissions disallow text extraction",
                    else => "PDF encryption could not be authenticated",
                },
            });
            return;
        };
        if (security.weak_crypto and !self.error_config.allow_weak_crypto) {
            if (!self.error_config.continue_on_parse_error) return error.WeakCryptoDisabled;
            try self.errors.append(self.allocator, .{
                .kind = .encrypted,
                .offset = 0,
                .message = "PDF uses weak encryption and weak crypto reading is disabled",
            });
            return;
        }
        if (!security.permissions.extract and self.error_config.respect_permissions) {
            if (!self.error_config.continue_on_parse_error) return error.PermissionDenied;
            try self.errors.append(self.allocator, .{
                .kind = .encrypted,
                .offset = 0,
                .message = "PDF permissions disallow text extraction",
            });
            return;
        }
        self.security = security;
    }

    /// Lazy-load fonts for a specific page (called on first extraction)
    fn ensurePageFonts(self: *Document, page_idx: usize) void {
        const arena = self.parsing_arena.allocator();
        const page = self.pages.items[page_idx];
        if (page.resources == null) return;
        const resources = page.resources.?;
        const fonts_dict_obj = resources.get("Font") orelse return;

        const fonts_dict_resolved = switch (fonts_dict_obj) {
            .reference => |ref| self.resolve(ref) catch null,
            else => fonts_dict_obj,
        };

        if (fonts_dict_resolved == null or fonts_dict_resolved.? != .dict) return;

        const fonts_dict = fonts_dict_resolved.?.dict;

        for (fonts_dict.entries) |entry| {
            // Create cache key for page:name lookup
            var key_buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ page_idx, entry.key }) catch continue;

            // Skip if already cached for this page
            if (self.font_cache.contains(key)) continue;

            // Check if font value is a reference - we can reuse by object ID
            const font_obj_id: ?u32 = switch (entry.value) {
                .reference => |ref| ref.num,
                else => null,
            };

            // If we've already parsed this object ID, reuse the encoding
            if (font_obj_id) |obj_id| {
                if (self.font_obj_cache.get(obj_id)) |cached_enc| {
                    // Reuse existing encoding - just add new key mapping
                    const owned_key = arena.dupe(u8, key) catch continue;
                    self.font_cache.put(owned_key, cached_enc) catch {};
                    continue;
                }
            }

            // Resolve font dictionary
            const font_obj = switch (entry.value) {
                .reference => |ref| self.resolve(ref) catch continue,
                .dict => entry.value,
                else => continue,
            };

            const fd = switch (font_obj) {
                .dict => |d| d,
                else => continue,
            };

            const Resolver = struct {
                arena: std.mem.Allocator,
                data: []const u8,
                xref_table: *const xref.XRefTable,
                object_cache: *std.AutoHashMap(u32, parser.Object),
                security: ?*const encryption.SecurityHandler,

                fn resolve(self_resolver: @This(), obj: parser.Object) parser.Object {
                    return switch (obj) {
                        .reference => |ref| pagetree.resolveRefWithSecurity(self_resolver.arena, self_resolver.data, self_resolver.xref_table, ref, self_resolver.object_cache, self_resolver.security) catch obj,
                        else => obj,
                    };
                }
            };
            const resolver = Resolver{
                .arena = arena,
                .data = self.data,
                .xref_table = &self.xref_table,
                .object_cache = &self.object_cache,
                .security = self.securityHandler(),
            };

            // Use the comprehensive parseFontEncoding
            var enc = encoding.parseFontEncoding(arena, fd, struct {
                fn wrapper(ctx: *const anyopaque, obj: parser.Object) parser.Object {
                    const r: *const Resolver = @ptrCast(@alignCast(ctx));
                    return r.resolve(obj);
                }
            }.wrapper, &resolver) catch continue;
            enc.font_object_num = font_obj_id;

            // Need to dupe key since bufPrint uses stack buffer
            const owned_key = arena.dupe(u8, key) catch continue;
            self.font_cache.put(owned_key, enc) catch {};

            // Cache by object ID for reuse across pages
            if (font_obj_id) |obj_id| {
                self.font_obj_cache.put(obj_id, enc) catch {};
            }
        }
    }

    /// Close the document and free resources
    pub fn close(self: *Document) void {
        if (self.owns_data and !is_wasm) {
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(@constCast(self.data.ptr)));
            if (self.data_is_allocated) {
                // Windows (always) or future POSIX allocated path
                self.allocator.free(aligned_ptr[0..self.data.len]);
            } else if (comptime !is_windows) {
                // POSIX: memory-mapped file
                std.posix.munmap(aligned_ptr[0..self.data.len]);
            }
        }

        // Free cached reading order
        if (self.cached_reading_order) |*cache| {
            var it = cache.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            cache.deinit();
        }

        // Free the arena which contains all parsed objects
        self.parsing_arena.deinit();

        self.xref_table.deinit();
        self.object_cache.deinit();
        self.errors.deinit(self.allocator);
        self.structural_diagnostics.deinit(self.allocator);
        self.pages.deinit(self.allocator);
        self.font_cache.deinit();
        self.font_obj_cache.deinit();
        if (self.source_path) |path| self.allocator.free(path);

        self.allocator.destroy(self);
    }

    /// Check if the document is encrypted
    pub fn isEncrypted(self: *const Document) bool {
        return self.xref_table.trailer.get("Encrypt") != null;
    }

    pub fn structuralDiagnostics(self: *const Document) []const structural.Diagnostic {
        return self.structural_diagnostics.items;
    }

    pub fn structuralSummary(self: *const Document) structural.Summary {
        var summary = structural.Summary{
            .xref_entries = self.xref_table.entries.count(),
            .trailer_size = self.xref_table.trailer.getInt("Size"),
            .has_root = self.xref_table.trailer.get("Root") != null,
            .has_encrypt = self.xref_table.trailer.get("Encrypt") != null,
        };
        var iterator = self.xref_table.entries.iterator();
        while (iterator.next()) |entry| {
            switch (entry.value_ptr.entry_type) {
                .free => summary.xref_free_entries += 1,
                .in_use => summary.xref_in_use_entries += 1,
                .compressed => {
                    summary.xref_compressed_entries += 1;
                    summary.object_stream_entries += 1;
                },
            }
        }
        return summary;
    }

    pub fn isAuthenticated(self: *const Document) bool {
        return self.security != null;
    }

    pub fn encryptionInfo(self: *const Document) encryption.Info {
        if (self.security) |security| return security.info();
        return .{ .encrypted = self.isEncrypted() };
    }

    fn securityHandler(self: *const Document) ?*const encryption.SecurityHandler {
        return if (self.security) |*security| security else null;
    }

    /// Get number of pages
    pub fn pageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    /// Inspect each extraction layer without changing the normal output path.
    /// This intentionally runs the bounds and final structured paths so a
    /// report can distinguish decoded operators/glyphs from usable output.
    pub fn inspectExtraction(self: *Document, allocator: std.mem.Allocator, pages: []const usize) !ExtractionDiagnostics {
        var report = ExtractionDiagnostics{
            .allocator = allocator,
            .document_page_count = self.pageCount(),
            .selected_page_count = pages.len,
        };
        var font_reports: std.ArrayList(extraction_diagnostics.FontReport) = .empty;
        defer font_reports.deinit(allocator);
        errdefer for (font_reports.items) |font_report| allocator.free(font_report.resource_name);

        for (pages) |page_num| {
            if (page_num >= self.pageCount()) continue;
            report.pages_scanned += 1;

            var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch_arena.deinit();
            const scratch_allocator = scratch_arena.allocator();

            const content = self.getPageContentForScratch(page_num, scratch_allocator) catch {
                report.content_stream_errors += 1;
                continue;
            };
            if (content.len == 0) {
                report.pages_without_content += 1;
            } else {
                report.pages_with_content += 1;
                report.decoded_content_bytes += content.len;
            }

            const page_text_operators_before = report.text_show_operator_count;
            scanExtractionOperators(scratch_allocator, content, &report) catch {
                report.operator_scan_errors += 1;
            };

            self.ensurePageFonts(page_num);
            var collector = interpreter.SpanCollector.init(scratch_allocator, @intCast(page_num));
            defer collector.deinit();
            var null_writer: NullWriter = .{};
            extractContentStream(content, .{ .bounds = &collector }, &self.font_cache, page_num, scratch_allocator, &null_writer) catch {
                report.page_extraction_errors += 1;
                continue;
            };
            try collector.flush();

            report.span_count += collector.getSpans().len;
            const page_glyph_count = collector.getGlyphs().len;
            report.glyph_count += page_glyph_count;
            for (collector.getGlyphs()) |glyph| {
                if (glyph.generated) continue;
                if (glyph.mapping_source == .unresolved) {
                    report.unmapped_glyph_count += 1;
                } else {
                    report.mapped_glyph_count += 1;
                }

                if (glyph.font_name) |resource_name| {
                    var key_buf: [256]u8 = undefined;
                    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ page_num, resource_name }) catch continue;
                    if (self.font_cache.getPtr(key)) |font| {
                        const font_report = try ensureFontReport(allocator, &font_reports, resource_name, font);
                        font_report.glyph_count += 1;
                        font_report.mapping_counts[@backingInt(glyph.mapping_source)] += 1;
                    }
                }
            }
            if (report.text_show_operator_count > page_text_operators_before and page_glyph_count == 0) {
                report.pages_with_text_operators_without_glyphs += 1;
            }

            var selection_metrics: StructuredSelectionMetrics = .{};
            const output = self.extractTextStructuredWithMetrics(page_num, scratch_allocator, &selection_metrics) catch {
                report.page_extraction_errors += 1;
                continue;
            };
            report.form_xobjects_decoded += selection_metrics.form_xobjects_decoded;
            report.selection_inventory_codepoints += selection_metrics.inventory_codepoints;
            report.selection_candidate_codepoints += selection_metrics.candidate_codepoints;
            report.selection_missing_codepoints += selection_metrics.missing_codepoints;
            report.selection_extra_codepoints += selection_metrics.extra_codepoints;
            switch (selection_metrics.selected) {
                .structured => report.pages_selected_structured += 1,
                .table => report.pages_selected_table += 1,
                .full_context => report.pages_selected_full_context += 1,
                .legacy_fallback => report.pages_selected_legacy_fallback += 1,
            }
            report.output_bytes += output.len;
            if (std.mem.trim(u8, output, " \t\r\n\x0c").len > 0) report.pages_with_output += 1;
            if (std.unicode.utf8ValidateSlice(output)) {
                report.output_codepoints += utf8CodepointCount(output);
            } else {
                report.invalid_utf8_pages += 1;
            }
        }

        report.fonts = try font_reports.toOwnedSlice(allocator);
        return report;
    }

    /// Free spans returned by extractTextWithBounds, including owned text.
    pub fn freeTextSpans(allocator: std.mem.Allocator, spans: []TextSpan) void {
        if (spans.len == 0) return;
        for (spans) |span| {
            if (span.text.len > 0) {
                allocator.free(@constCast(span.text));
            }
            if (span.font.name) |name| {
                allocator.free(@constCast(name));
            }
        }
        allocator.free(spans);
    }

    /// Free glyph geometry returned by extractNativePageGeometry.
    pub fn freeGlyphSpans(allocator: std.mem.Allocator, glyphs: []GlyphSpan) void {
        if (glyphs.len == 0) return;
        for (glyphs) |glyph| {
            if (glyph.text.len > 0) allocator.free(@constCast(glyph.text));
            if (glyph.font_name) |name| allocator.free(@constCast(name));
        }
        allocator.free(glyphs);
    }

    /// Resolve an object reference
    pub fn resolve(self: *Document, ref: ObjRef) !Object {
        return pagetree.resolveRefWithSecurity(
            self.parsing_arena.allocator(),
            self.data,
            &self.xref_table,
            ref,
            &self.object_cache,
            self.securityHandler(),
        );
    }

    /// Extract text from a page, streaming directly to writer
    pub fn extractText(self: *Document, page_num: usize, writer: anytype) !void {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        const parse_allocator = self.parsing_arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        // Get content stream (allocated from arena, no need to free)
        const content = pagetree.getPageContentsWithSecurity(
            parse_allocator,
            scratch_allocator,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
            self.securityHandler(),
        ) catch |err| {
            if (self.error_config.continue_on_parse_error) {
                try self.errors.append(self.allocator, .{
                    .kind = .invalid_stream,
                    .offset = 0,
                    .message = "Failed to get page contents",
                });
                return;
            } else {
                return err;
            }
        };

        if (content.len == 0) return;

        // Lazy-load fonts for this page
        self.ensurePageFonts(page_num);

        // Extract text with full Form XObject support
        const ctx = ExtractionContext{
            .parse_allocator = parse_allocator,
            .scratch_allocator = scratch_allocator,
            .data = self.data,
            .xref_table = &self.xref_table,
            .object_cache = &self.object_cache,
            .font_cache = &self.font_cache,
            .page_num = page_num,
            .depth = 0,
            .security = self.securityHandler(),
        };
        try extractTextFromContentFull(content, page.resources, &ctx, writer);
    }

    /// Extract text from all pages
    pub fn extractAllText(self: *Document, writer: anytype) !void {
        for (0..self.pages.items.len) |i| {
            if (i > 0) try writer.writeByte('\x0c'); // Form feed between pages
            try self.extractText(i, writer);
        }
    }

    /// Extract text with bounding boxes from a page
    pub fn extractTextWithBounds(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]TextSpan {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = self.getPageContentForScratch(page_num, scratch_allocator) catch return &.{};
        return self.extractTextWithBoundsFromContent(page_num, allocator, scratch_allocator, content);
    }

    /// Return decoded page contents allocated from caller-owned scratch memory.
    /// The returned slice is valid while scratch_allocator's backing storage lives.
    pub fn getPageContentForScratch(self: *Document, page_num: usize, scratch_allocator: std.mem.Allocator) ![]const u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        return pagetree.getPageContentsWithSecurity(
            self.parsing_arena.allocator(),
            scratch_allocator,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
            self.securityHandler(),
        );
    }

    /// Extract text with bounding boxes from already-decoded page content.
    /// This lets adaptive extraction reuse one page content decode across passes.
    pub fn extractTextWithBoundsFromContent(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
    ) ![]TextSpan {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        if (content.len == 0) return &.{};

        // Lazy-load fonts for this page (needed for proper text decoding)
        self.ensurePageFonts(page_num);

        var collector = interpreter.SpanCollector.init(allocator, @intCast(page_num));
        errdefer collector.deinit();

        {
            var nw: NullWriter = .{};
            var traversal = form_scope.Traversal{ .page_index = @intCast(page_num) };
            const context = self.contentContext(page_num, scratch_allocator, &traversal);
            try extractContentStreamContext(content, .{ .bounds = &collector }, &self.font_cache, page_num, scratch_allocator, &nw, &context);
        }
        try collector.flush();

        const spans = try collector.toOwnedSlice();
        collector.deinit();
        return spans;
    }

    /// Extract both compatibility spans and glyph-level geometry for native
    /// layout reconstruction. Ownership of both slices belongs to the caller.
    pub fn extractNativePageGeometry(self: *Document, page_num: usize, allocator: std.mem.Allocator) !NativePageGeometry {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const content = self.getPageContentForScratch(page_num, scratch_allocator) catch return .{
            .allocator = allocator,
            .spans = try allocator.alloc(TextSpan, 0),
            .glyphs = try allocator.alloc(GlyphSpan, 0),
        };
        return self.extractNativePageGeometryFromContent(page_num, allocator, scratch_allocator, content);
    }

    pub fn extractNativePageGeometryFromContent(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
    ) !NativePageGeometry {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        if (content.len == 0) return .{
            .allocator = allocator,
            .spans = try allocator.alloc(TextSpan, 0),
            .glyphs = try allocator.alloc(GlyphSpan, 0),
        };

        self.ensurePageFonts(page_num);
        var collector = interpreter.SpanCollector.init(allocator, @intCast(page_num));
        errdefer collector.deinit();
        var null_writer: NullWriter = .{};
        var traversal = form_scope.Traversal{ .page_index = @intCast(page_num) };
        const context = self.contentContext(page_num, scratch_allocator, &traversal);
        try extractContentStreamContext(content, .{ .bounds = &collector }, &self.font_cache, page_num, scratch_allocator, &null_writer, &context);
        try collector.flush();

        const spans = try collector.toOwnedSlice();
        errdefer Document.freeTextSpans(allocator, spans);
        const semantic_glyphs = if (collector.actual_text_runs.items.len > 0) try collector.toOwnedSemanticGlyphSlice() else null;
        errdefer if (semantic_glyphs) |glyphs| Document.freeGlyphSpans(allocator, glyphs);
        const glyphs = try collector.toOwnedGlyphSlice();
        collector.deinit();
        return .{ .allocator = allocator, .spans = spans, .glyphs = glyphs, .semantic_glyphs = semantic_glyphs };
    }

    /// Glyph-first native layout for a page. The raw recall text is used only
    /// as a completeness oracle; it is retained independently by callers.
    pub fn analyzeNativePageLayout(self: *Document, page_num: usize, allocator: std.mem.Allocator) !NativeLayoutResult {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const content = try self.getPageContentForScratch(page_num, scratch_allocator);
        const raw = try self.extractTextFullContextFromContent(page_num, allocator, scratch_allocator, content, null);
        defer allocator.free(raw);
        var geometry = try self.extractNativePageGeometryFromContent(page_num, allocator, scratch_allocator, content);
        defer geometry.deinit();
        const page = self.pages.items[page_num];
        return native_layout.analyze(allocator, geometry.semantic_glyphs orelse geometry.glyphs, .{
            .x0 = page.media_box[0],
            .y0 = page.media_box[1],
            .x1 = page.media_box[2],
            .y1 = page.media_box[3],
        }, raw);
    }

    fn contentContext(self: *Document, page_num: usize, scratch_allocator: std.mem.Allocator, traversal: *form_scope.Traversal) ExtractionContext {
        return .{
            .parse_allocator = self.parsing_arena.allocator(),
            .scratch_allocator = scratch_allocator,
            .data = self.data,
            .xref_table = &self.xref_table,
            .object_cache = &self.object_cache,
            .font_cache = &self.font_cache,
            .page_num = page_num,
            .depth = 0,
            .security = self.securityHandler(),
            .resources = self.pages.items[page_num].resources,
            .traversal = traversal,
            .scope = form_scope.Scope.page(@intCast(page_num)),
        };
    }

    /// Analyze page layout (columns, paragraphs, reading order)
    pub fn analyzePageLayout(self: *Document, page_num: usize, allocator: std.mem.Allocator) !LayoutResult {
        const spans = try self.extractTextWithBounds(page_num, allocator);
        const page = self.pages.items[page_num];
        const page_width = page.media_box[2] - page.media_box[0];
        const ruling_lines = try self.getPageRulingLines(page_num, allocator);
        defer allocator.free(ruling_lines);
        return layout.analyzeLayoutWithRulings(allocator, spans, page_width, ruling_lines);
    }

    /// Run the Sprint 2 adaptive native pipeline:
    /// native spans -> layout blocks -> complexity routes -> trace stubs -> reconciler.
    pub fn extractAdaptive(
        self: *Document,
        allocator: std.mem.Allocator,
        options: adaptive.ExtractOptions,
    ) !adaptive.Result {
        return adaptive.extractDocument(allocator, self, options);
    }

    /// Stream adaptive JSONL artifacts one page at a time.
    pub fn extractAdaptiveStreaming(
        self: *Document,
        allocator: std.mem.Allocator,
        writer: anytype,
        options: stream.StreamingOptions,
    ) !stream.StreamingSummary {
        return stream.extractAdaptiveStreaming(allocator, self, writer, options);
    }

    /// Score a page before OCR/ML routing. The score is derived only from
    /// cheap native evidence: text spans, font metadata, image boxes, and
    /// geometric distribution.
    pub fn analyzePageComplexity(self: *Document, page_num: usize, allocator: std.mem.Allocator) !complexity.PageScore {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        const spans = try self.extractTextWithBounds(page_num, allocator);
        defer Document.freeTextSpans(allocator, spans);

        const images = try self.getPageImages(page_num, allocator);
        defer Document.freeImages(allocator, images);

        const image_boxes = try allocator.alloc(complexity.ImageBox, images.len);
        defer allocator.free(image_boxes);
        for (images, 0..) |image, i| {
            image_boxes[i] = .{
                .bbox = .{
                    .x0 = image.rect[0],
                    .y0 = image.rect[1],
                    .x1 = image.rect[2],
                    .y1 = image.rect[3],
                },
                .pixel_width = image.width,
                .pixel_height = image.height,
            };
        }

        return complexity.scorePage(.{
            .page_index = @intCast(page_num),
            .bbox = .{
                .x0 = page.media_box[0],
                .y0 = page.media_box[1],
                .x1 = page.media_box[2],
                .y1 = page.media_box[3],
            },
            .spans = spans,
            .images = image_boxes,
            .has_structure_tree = self.hasStructureTree(),
        });
    }

    /// Check if the document has a structure tree (is tagged)
    pub fn hasStructureTree(self: *Document) bool {
        const arena = self.parsing_arena.allocator();

        // Get Root from trailer
        const root_ref = switch (self.xref_table.trailer.get("Root") orelse return false) {
            .reference => |r| r,
            else => return false,
        };

        const catalog = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, root_ref, &self.object_cache, self.securityHandler()) catch return false;

        const catalog_dict = switch (catalog) {
            .dict => |d| d,
            else => return false,
        };

        return catalog_dict.get("StructTreeRoot") != null;
    }

    /// Ensure reading order is parsed and cached (called once per document)
    fn ensureReadingOrder(self: *Document) void {
        if (self.reading_order_parsed) return;
        self.reading_order_parsed = true;

        const arena = self.parsing_arena.allocator();

        // Parse structure tree once
        var tree = structtree.parseStructTree(arena, self.data, &self.xref_table, &self.object_cache) catch return;
        defer tree.deinit();

        if (tree.root == null) return;

        // Build page index mapping (object number -> page index)
        var page_obj_to_idx = std.AutoHashMap(u32, usize).init(arena);
        for (self.pages.items, 0..) |p, idx| {
            page_obj_to_idx.put(p.ref.num, idx) catch continue;
        }

        // Get reading order for all pages
        var reading_order = tree.getReadingOrder(arena) catch return;

        // Build per-page reading order cache
        var cache = std.AutoHashMap(usize, std.ArrayList(structtree.MarkedContentRef)).init(self.allocator);
        var has_entries = false;

        var it = reading_order.iterator();
        while (it.next()) |entry| {
            const obj_num = entry.key_ptr.*;
            if (page_obj_to_idx.get(@intCast(obj_num))) |page_idx| {
                var page_mcids = cache.getPtr(page_idx) orelse blk: {
                    cache.put(page_idx, .empty) catch continue;
                    break :blk cache.getPtr(page_idx).?;
                };
                for (entry.value_ptr.items) |mcr| {
                    page_mcids.append(self.allocator, mcr) catch continue;
                    has_entries = true;
                }
            }
        }

        // Only set cache if we have actual entries
        if (has_entries) {
            self.cached_reading_order = cache;
        } else {
            cache.deinit();
        }
    }

    /// Return the borrowed structure-tree MCID sequence for one page.
    ///
    /// The slice is owned by the document and remains valid until `close`.
    /// Missing, malformed, or empty structure trees are reported as `null` so
    /// adaptive layout can fall back to geometric evidence without changing
    /// extraction failure semantics.
    pub fn pageMarkedContentOrder(self: *Document, page_num: usize) ?[]const structtree.MarkedContentRef {
        if (page_num >= self.pages.items.len) return null;
        self.ensureReadingOrder();
        if (self.cached_reading_order) |*cache| {
            if (cache.get(page_num)) |mcids| return mcids.items;
        }
        return null;
    }

    /// Extract text using structure tree reading order (for tagged PDFs)
    /// Falls back to geometric sorting if no structure tree is present
    pub fn extractTextStructured(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        return self.extractTextStructuredWithMetrics(page_num, allocator, null);
    }

    fn extractTextStructuredWithMetrics(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        selection_metrics: ?*StructuredSelectionMetrics,
    ) ![]u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        if (selection_metrics) |metrics| metrics.* = .{};

        // Ensure reading order is cached (done once per document)
        self.ensureReadingOrder();

        const parse_allocator = self.parsing_arena.allocator();
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const page = self.pages.items[page_num];

        // Get content stream
        const content = pagetree.getPageContentsWithSecurity(
            parse_allocator,
            scratch_allocator,
            self.data,
            &self.xref_table,
            page,
            &self.object_cache,
            self.securityHandler(),
        ) catch return self.withPageFormFields(page_num, allocator, try allocator.alloc(u8, 0));

        if (content.len == 0) {
            return self.withPageFormFields(page_num, allocator, try allocator.alloc(u8, 0));
        }

        // Lazy-load fonts for this page
        self.ensurePageFonts(page_num);

        // Build the completeness oracle with page resources and recursive Form
        // XObject handling. Reading-order candidates may reorder this content,
        // but they must not silently discard any non-whitespace Unicode scalar.
        var full_context_text = self.extractTextFullContextFromContent(
            page_num,
            allocator,
            scratch_allocator,
            content,
            selection_metrics,
        ) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            break :blk null;
        };
        errdefer if (full_context_text) |text| allocator.free(text);
        if (full_context_text) |text| {
            if (selection_metrics) |metrics| {
                metrics.inventory_codepoints = comparableCodepointCount(text);
            }
        }

        // Check if we have cached reading order for this page
        if (self.cached_reading_order) |*cache| {
            if (cache.get(page_num)) |mcids| {
                // Extract text with MCID tracking
                var extractor = structtree.MarkedContentExtractor.init(scratch_allocator);
                defer extractor.deinit();

                {
                    var nw: NullWriter = .{};
                    var traversal = form_scope.Traversal{ .page_index = @intCast(page_num) };
                    const context = self.contentContext(page_num, scratch_allocator, &traversal);
                    extractContentStreamContext(content, .{ .structured = &extractor }, &self.font_cache, page_num, scratch_allocator, &nw, &context) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        if (full_context_text) |inventory| {
                            full_context_text = null;
                            if (selection_metrics) |metrics| metrics.selected = .full_context;
                            const readable = try self.readableFromInventory(page_num, allocator, scratch_allocator, content, inventory);
                            return self.withPageFormFields(page_num, allocator, readable);
                        }
                        if (selection_metrics) |metrics| metrics.selected = .legacy_fallback;
                        const geometric = try self.extractTextGeometricFromContent(page_num, allocator, scratch_allocator, content);
                        return self.withPageFormFields(page_num, allocator, geometric);
                    };
                }

                // Collect text in structure tree order
                var result: std.ArrayList(u8) = .empty;
                errdefer result.deinit(allocator);
                // Pre-size: ~50 bytes per MCID on average
                try result.ensureTotalCapacity(allocator, mcids.items.len * 50);

                for (mcids.items) |mcr| {
                    if (extractor.getTextForScopedMcid(mcr.stream_ref, mcr.mcid)) |text| {
                        if (result.items.len > 0 and text.len > 0) {
                            try result.append(allocator, ' ');
                        }
                        try result.appendSlice(allocator, text);
                    }
                }

                if (result.items.len > 0) {
                    const structured = try result.toOwnedSlice(allocator);
                    if (full_context_text) |inventory| {
                        const comparison = compareTextContent(scratch_allocator, inventory, structured) catch |err| {
                            allocator.free(structured);
                            return err;
                        };
                        if (selection_metrics) |metrics| metrics.recordCandidate(comparison);
                        if (comparison.equivalent()) {
                            allocator.free(inventory);
                            full_context_text = null;
                            if (selection_metrics) |metrics| metrics.selected = .structured;
                            return self.withPageFormFields(page_num, allocator, structured);
                        }
                        allocator.free(structured);
                        full_context_text = null;
                        if (selection_metrics) |metrics| metrics.selected = .full_context;
                        const readable = try self.readableFromInventory(page_num, allocator, scratch_allocator, content, inventory);
                        return self.withPageFormFields(page_num, allocator, readable);
                    }
                    if (selection_metrics) |metrics| metrics.selected = .legacy_fallback;
                    if (std.mem.trim(u8, structured, " \t\r\n\x0c").len > 0) {
                        return self.withPageFormFields(page_num, allocator, structured);
                    }
                    allocator.free(structured);
                }
                result.deinit(allocator);
            }
        }

        if (try self.extractTextTableAwareFromContent(page_num, allocator, scratch_allocator, content)) |table_text| {
            if (full_context_text) |inventory| {
                const comparison = compareTextContent(scratch_allocator, inventory, table_text) catch |err| {
                    allocator.free(table_text);
                    return err;
                };
                if (selection_metrics) |metrics| metrics.recordCandidate(comparison);
                if (comparison.equivalent()) {
                    allocator.free(inventory);
                    full_context_text = null;
                    if (selection_metrics) |metrics| metrics.selected = .table;
                    return self.withPageFormFields(page_num, allocator, table_text);
                }
                allocator.free(table_text);
                full_context_text = null;
                if (selection_metrics) |metrics| metrics.selected = .full_context;
                const readable = try self.readableFromInventory(page_num, allocator, scratch_allocator, content, inventory);
                return self.withPageFormFields(page_num, allocator, readable);
            }
            if (selection_metrics) |metrics| metrics.selected = .legacy_fallback;
            return self.withPageFormFields(page_num, allocator, table_text);
        }

        if (full_context_text) |inventory| {
            full_context_text = null;
            if (selection_metrics) |metrics| metrics.selected = .full_context;
            const readable = try self.readableFromInventory(page_num, allocator, scratch_allocator, content, inventory);
            return self.withPageFormFields(page_num, allocator, readable);
        }

        // Legacy fallback for domain errors in full-context extraction.
        const stream_text = self.extractTextStreamOrderFromContent(page_num, allocator, scratch_allocator, content) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (selection_metrics) |metrics| metrics.selected = .legacy_fallback;
            return self.extractTextGeometricFromContent(page_num, allocator, scratch_allocator, content);
        };
        if (selection_metrics) |metrics| metrics.selected = .legacy_fallback;
        if (stream_text.len > 0) {
            return self.withPageFormFields(page_num, allocator, stream_text);
        }

        allocator.free(stream_text);
        return self.withPageFormFields(page_num, allocator, try self.extractTextGeometricFromContent(page_num, allocator, scratch_allocator, content));
    }

    /// Render value-bearing AcroForm fields as stable "name value" text lines.
    /// This mirrors how form-aware extractors expose widgets separately while
    /// still making field values visible to plain-text/RAG consumers.
    pub fn extractFormFieldText(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const fields = try self.getFormFields(allocator);
        defer Document.freeFormFields(allocator, fields);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var writer = runtime.arrayListWriter(&output, allocator);

        for (fields) |field| {
            const value = field.value orelse continue;
            if (field.name.len == 0 or value.len == 0) continue;
            try writer.print("{s} {s}\n", .{ field.name, value });
        }

        if (output.items.len > 0) {
            output.items.len -= 1;
        }

        return output.toOwnedSlice(allocator);
    }

    fn withPageFormFields(self: *Document, page_num: usize, allocator: std.mem.Allocator, page_text: []u8) ![]u8 {
        errdefer allocator.free(page_text);

        // The current AcroForm reader is document-scoped. Append once to avoid
        // duplicating global field values across multi-page extraction.
        if (page_num != 0) return page_text;

        const form_text = try self.extractFormFieldText(allocator);
        defer allocator.free(form_text);
        if (form_text.len == 0) return page_text;

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, page_text.len + form_text.len + 1);
        try output.appendSlice(allocator, page_text);
        if (page_text.len > 0) {
            try output.append(allocator, '\n');
        }
        try output.appendSlice(allocator, form_text);
        allocator.free(page_text);
        return output.toOwnedSlice(allocator);
    }

    fn extractTextTableAware(self: *Document, page_num: usize, allocator: std.mem.Allocator) !?[]u8 {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = self.getPageContentForScratch(page_num, scratch_allocator) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
        return self.extractTextTableAwareFromContent(page_num, allocator, scratch_allocator, content);
    }

    fn extractTextTableAwareFromContent(self: *Document, page_num: usize, allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
        const page = self.pages.items[page_num];
        const page_width = page.media_box[2] - page.media_box[0];

        const spans = self.extractTextWithBoundsFromContent(page_num, scratch_allocator, scratch_allocator, content) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
        if (spans.len == 0) return null;

        const ruling_lines = self.getPageRulingLinesFromContent(page_num, scratch_allocator, scratch_allocator, content) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
        var page_layout = layout.analyzeLayoutWithRulings(scratch_allocator, spans, page_width, ruling_lines) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
        defer page_layout.deinit();

        if (page_layout.tables.len == 0) return null;
        const table_text = try page_layout.getCompleteReconstructedText(allocator);
        return table_text;
    }

    /// Extract text using geometric sorting (fallback when no structure tree)
    /// Simple Y→X sort to match PyMuPDF's sort=True behavior
    fn extractTextGeometric(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        // Keep intermediate span allocations in per-call scratch memory to avoid
        // persistent allocator churn on repeated full-document extraction.
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = self.getPageContentForScratch(page_num, scratch_allocator) catch |err| {
            // If bounds extraction fails, fall back to stream order
            if (err == error.OutOfMemory) return err;
            return self.extractTextStreamOrder(page_num, allocator);
        };
        return self.extractTextGeometricFromContent(page_num, allocator, scratch_allocator, content);
    }

    fn extractTextGeometricFromContent(self: *Document, page_num: usize, allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, content: []const u8) ![]u8 {
        const spans = self.extractTextWithBoundsFromContent(page_num, scratch_allocator, scratch_allocator, content) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.extractTextStreamOrderFromContent(page_num, allocator, scratch_allocator, content);
        };
        if (spans.len == 0) {
            return allocator.alloc(u8, 0);
        }

        return layout.sortGeometric(allocator, spans) catch {
            return self.extractTextStreamOrderFromContent(page_num, allocator, scratch_allocator, content);
        };
    }

    /// Extract text in raw stream order (last resort fallback)
    fn extractTextStreamOrder(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        // Pre-size for typical page: ~2KB of text
        try output.ensureTotalCapacity(allocator, 2048);

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const content = self.getPageContentForScratch(page_num, scratch_allocator) catch return output.toOwnedSlice(allocator);

        try self.extractTextStreamOrderFromContentInto(page_num, scratch_allocator, content, runtime.arrayListWriter(&output, allocator));
        return output.toOwnedSlice(allocator);
    }

    /// Extract one page through the cheaper stream-order lane.
    pub fn extractTextFast(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        return self.withPageFormFields(page_num, allocator, try self.extractTextStreamOrder(page_num, allocator));
    }

    fn extractTextStreamOrderFromContent(self: *Document, page_num: usize, allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, content: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, 2048);

        try self.extractTextStreamOrderFromContentInto(page_num, scratch_allocator, content, runtime.arrayListWriter(&output, allocator));
        return output.toOwnedSlice(allocator);
    }

    fn extractTextStreamOrderFromContentInto(self: *Document, page_num: usize, scratch_allocator: std.mem.Allocator, content: []const u8, writer: anytype) !void {
        self.ensurePageFonts(page_num);
        var traversal = form_scope.Traversal{ .page_index = @intCast(page_num) };
        const context = self.contentContext(page_num, scratch_allocator, &traversal);
        try extractContentStreamContext(content, .{ .stream = .{ .resources = context.resources, .ctx = &context } }, &self.font_cache, page_num, scratch_allocator, writer, &context);
    }

    fn extractTextNativeLayoutFromContent(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
        raw_recall_text: []const u8,
        quality: ?*NativeLayoutQuality,
    ) ![]u8 {
        var geometry = try self.extractNativePageGeometryFromContent(page_num, allocator, scratch_allocator, content);
        defer geometry.deinit();
        const page = self.pages.items[page_num];
        var native_result = try native_layout.analyze(allocator, geometry.semantic_glyphs orelse geometry.glyphs, .{
            .x0 = page.media_box[0],
            .y0 = page.media_box[1],
            .x1 = page.media_box[2],
            .y1 = page.media_box[3],
        }, raw_recall_text);
        defer native_result.deinit();
        if (quality) |out| out.* = native_result.quality;
        return allocator.dupe(u8, native_result.text);
    }

    fn readableFromInventory(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
        inventory: []u8,
    ) ![]u8 {
        var quality: NativeLayoutQuality = .{};
        const readable = self.extractTextNativeLayoutFromContent(
            page_num,
            allocator,
            scratch_allocator,
            content,
            inventory,
            &quality,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            return inventory;
        };

        // Layout may reorder whitespace, but it must not silently trade away
        // native content recall. Keep the loss-minimizing inventory if the
        // glyph pass cannot account for nearly all non-whitespace characters.
        if (quality.raw_non_whitespace_recall < 0.995) {
            allocator.free(readable);
            return inventory;
        }
        allocator.free(inventory);
        return readable;
    }

    fn extractTextFullContextFromContent(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
        selection_metrics: ?*StructuredSelectionMetrics,
    ) ![]u8 {
        self.ensurePageFonts(page_num);
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, 2048);

        const page = self.pages.items[page_num];
        const ctx = ExtractionContext{
            .parse_allocator = self.parsing_arena.allocator(),
            .scratch_allocator = scratch_allocator,
            .data = self.data,
            .xref_table = &self.xref_table,
            .object_cache = &self.object_cache,
            .font_cache = &self.font_cache,
            .page_num = page_num,
            .depth = 0,
            .security = self.securityHandler(),
            .selection_metrics = selection_metrics,
        };
        try extractTextFromContentFull(content, page.resources, &ctx, runtime.arrayListWriter(&output, allocator));
        return output.toOwnedSlice(allocator);
    }

    /// Loss-minimizing content-stream text. This is intentionally separate
    /// from readable extraction so search/diagnostics can retain raw recall.
    pub fn extractTextRawRecall(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const content = try self.getPageContentForScratch(page_num, scratch_allocator);
        return self.extractTextFullContextFromContent(page_num, allocator, scratch_allocator, content, null);
    }

    pub fn extractTextReadable(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        quality: ?*NativeLayoutQuality,
    ) ![]u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();
        const content = try self.getPageContentForScratch(page_num, scratch_allocator);
        const raw = try self.extractTextFullContextFromContent(page_num, allocator, scratch_allocator, content, null);
        defer allocator.free(raw);
        return self.extractTextNativeLayoutFromContent(page_num, allocator, scratch_allocator, content, raw, quality);
    }

    /// Extract text from all pages using structure tree order
    pub fn extractAllTextStructured(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        // Parse and cache structure tree once for the full document.
        self.ensureReadingOrder();

        // Pre-load all fonts for smaller docs to reduce per-page overhead.
        // Untagged pages still flow through per-page structured extraction so
        // table-like pages can opt into layout reconstruction before falling
        // back to stream order.
        if (num_pages <= 100) {
            for (0..num_pages) |i| {
                self.ensurePageFonts(i);
            }
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        // Pre-size buffer: ~2KB average text per page
        try result.ensureTotalCapacity(allocator, num_pages * 2048);

        for (0..num_pages) |page_num| {
            if (page_num > 0) try result.append(allocator, '\x0c'); // Form feed
            // Keep per-page extraction intermediates off the caller allocator.
            {
                var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch_arena.deinit();
                const scratch_allocator = scratch_arena.allocator();

                const page_text = self.extractTextStructured(page_num, scratch_allocator) catch continue;
                try result.appendSlice(allocator, page_text);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Extract every page through the loss-minimizing raw recall channel.
    pub fn extractAllTextRawRecall(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, self.pages.items.len * 2048);
        for (0..self.pages.items.len) |page_num| {
            if (page_num > 0) try result.append(allocator, '\x0c');
            const page_text = self.extractTextRawRecall(page_num, allocator) catch continue;
            defer allocator.free(page_text);
            try result.appendSlice(allocator, page_text);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Extract text from all pages in fast stream-order mode.
    pub fn extractAllTextFast(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        // Pre-load fonts for smaller docs to reduce per-page overhead.
        if (num_pages <= 100) {
            for (0..num_pages) |i| {
                self.ensurePageFonts(i);
            }
        }

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, num_pages * 2048);

        const parse_allocator = self.parsing_arena.allocator();

        for (0..num_pages) |page_num| {
            if (page_num > 0) try result.append(allocator, '\x0c');
            {
                var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch_arena.deinit();
                const scratch_allocator = scratch_arena.allocator();

                const page = self.pages.items[page_num];
                const content = pagetree.getPageContentsWithSecurity(
                    parse_allocator,
                    scratch_allocator,
                    self.data,
                    &self.xref_table,
                    page,
                    &self.object_cache,
                    self.securityHandler(),
                ) catch continue;

                if (content.len == 0) continue;
                try self.extractTextStreamOrderFromContentInto(page_num, scratch_allocator, content, runtime.arrayListWriter(&result, allocator));
            }
        }

        const form_text = try self.extractFormFieldText(allocator);
        defer allocator.free(form_text);
        if (form_text.len > 0) {
            if (result.items.len > 0) try result.append(allocator, '\n');
            try result.appendSlice(allocator, form_text);
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn extractAllTextWithMode(self: *Document, allocator: std.mem.Allocator, mode: FullTextMode) ![]u8 {
        return switch (mode) {
            .accuracy => self.extractAllTextStructured(allocator),
            .raw_recall => self.extractAllTextRawRecall(allocator),
            .fast => self.extractAllTextFast(allocator),
        };
    }

    /// Extract text from a page as Markdown
    pub fn extractMarkdown(self: *Document, page_num: usize, allocator: std.mem.Allocator) ![]u8 {
        return self.extractMarkdownWithOptions(page_num, allocator, markdown.MarkdownOptions{});
    }

    /// Extract text from a page as Markdown with custom options
    pub fn extractMarkdownWithOptions(
        self: *Document,
        page_num: usize,
        allocator: std.mem.Allocator,
        options: markdown.MarkdownOptions,
    ) ![]u8 {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        const page_width = page.media_box[2] - page.media_box[0];

        // Extract spans with bounds
        const spans = try self.extractTextWithBounds(page_num, allocator);
        if (spans.len == 0) {
            Document.freeTextSpans(allocator, spans);
            return allocator.alloc(u8, 0);
        }
        defer Document.freeTextSpans(allocator, spans);

        // Render to Markdown
        var renderer = markdown.MarkdownRenderer.init(allocator, options);
        return renderer.render(spans, page_width);
    }

    pub fn writePageTablesJson(self: *Document, page_num: usize, allocator: std.mem.Allocator, writer: anytype) !void {
        if (page_num >= self.pages.items.len) return error.PageNotFound;

        const page = self.pages.items[page_num];
        const page_width = page.media_box[2] - page.media_box[0];
        const spans = try self.extractTextWithBounds(page_num, allocator);
        defer Document.freeTextSpans(allocator, spans);

        const ruling_lines = try self.getPageRulingLines(page_num, allocator);
        defer allocator.free(ruling_lines);
        var page_layout = try layout.analyzeLayoutWithRulings(allocator, spans, page_width, ruling_lines);
        defer page_layout.deinit();
        try page_layout.writeTablesJson(writer);
    }

    /// Extract text from all pages as Markdown
    pub fn extractAllMarkdown(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        return self.extractAllMarkdownWithOptions(allocator, markdown.MarkdownOptions{});
    }

    /// Extract text from all pages as Markdown with custom options
    pub fn extractAllMarkdownWithOptions(
        self: *Document,
        allocator: std.mem.Allocator,
        options: markdown.MarkdownOptions,
    ) ![]u8 {
        const num_pages = self.pages.items.len;
        if (num_pages == 0) return allocator.alloc(u8, 0);

        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        // Pre-size: ~3KB average per page for markdown
        try result.ensureTotalCapacity(allocator, num_pages * 3072);

        for (0..num_pages) |page_num| {
            if (page_num > 0 and options.page_breaks_as_hr) {
                try result.appendSlice(allocator, "\n---\n\n");
            }

            const page_md = self.extractMarkdownWithOptions(page_num, allocator, options) catch continue;
            defer allocator.free(page_md);

            try result.appendSlice(allocator, page_md);
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get page metadata
    pub fn getPageInfo(self: *const Document, page_num: usize) ?PageInfo {
        if (page_num >= self.pages.items.len) return null;

        const page = self.pages.items[page_num];
        return .{
            .width = page.media_box[2] - page.media_box[0],
            .height = page.media_box[3] - page.media_box[1],
            .rotation = page.rotation,
        };
    }

    pub const PageInfo = struct {
        width: f64,
        height: f64,
        rotation: i32,
    };

    /// Canonical PDF coordinates remain unchanged. These page-local matrices
    /// map them to physical points at the selected box's top-left display origin.
    pub fn getPageGeometry(self: *const Document, page_num: usize) ?page_geometry.PageGeometry {
        if (page_num >= self.pages.items.len) return null;
        const page = self.pages.items[page_num];
        return page_geometry.PageGeometry.init(
            .{ .x0 = page.media_box[0], .y0 = page.media_box[1], .x1 = page.media_box[2], .y1 = page.media_box[3] },
            .{ .x0 = page.crop_box[0], .y0 = page.crop_box[1], .x1 = page.crop_box[2], .y1 = page.crop_box[3] },
            page.rotation,
            page.user_unit,
        ) catch null;
    }

    // =========================================================================
    // Feature 1: Document Metadata (/Info dict)
    // =========================================================================

    pub const DocumentMetadata = struct {
        title: ?[]const u8 = null,
        author: ?[]const u8 = null,
        subject: ?[]const u8 = null,
        keywords: ?[]const u8 = null,
        creator: ?[]const u8 = null,
        producer: ?[]const u8 = null,
        creation_date: ?[]const u8 = null,
        mod_date: ?[]const u8 = null,
    };

    /// Extract document metadata from the /Info dictionary
    pub fn metadata(self: *Document) DocumentMetadata {
        const info_ref = self.xref_table.trailer.get("Info") orelse return .{};
        const dict = switch (info_ref) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = self.resolve(r) catch return .{};
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return .{},
                };
            },
            else => return .{},
        };
        return .{
            .title = dict.getString("Title"),
            .author = dict.getString("Author"),
            .subject = dict.getString("Subject"),
            .keywords = dict.getString("Keywords"),
            .creator = dict.getString("Creator"),
            .producer = dict.getString("Producer"),
            .creation_date = dict.getString("CreationDate"),
            .mod_date = dict.getString("ModDate"),
        };
    }

    // =========================================================================
    // Feature 2: Document Outline / TOC (/Outlines)
    // =========================================================================

    pub const OutlineItem = outline.OutlineItem;

    /// Extract the document outline (table of contents / bookmarks)
    pub fn getOutline(self: *Document, allocator: std.mem.Allocator) ![]OutlineItem {
        return outline.parseOutline(
            allocator,
            self.parsing_arena.allocator(),
            self.data,
            &self.xref_table,
            &self.object_cache,
            self.pages.items,
        );
    }

    // =========================================================================
    // Feature 3: Page Labels (/PageLabels)
    // =========================================================================

    /// Get the display label for a page (e.g., "i", "ii", "1", "2", "A-1")
    /// Caller must free the returned slice.
    pub fn getPageLabel(self: *Document, allocator: std.mem.Allocator, page_idx: usize) ?[]u8 {
        const arena = self.parsing_arena.allocator();

        // Get catalog
        const root_ref = switch (self.xref_table.trailer.get("Root") orelse return null) {
            .reference => |r| r,
            else => return null,
        };
        const catalog = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, root_ref, &self.object_cache, self.securityHandler()) catch return null;
        const catalog_dict = switch (catalog) {
            .dict => |d| d,
            else => return null,
        };

        // Get /PageLabels number tree
        const pl_obj = catalog_dict.get("PageLabels") orelse return null;
        const pl_dict = switch (pl_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch return null;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return null,
                };
            },
            else => return null,
        };

        // Get /Nums array
        const nums_arr = blk: {
            const nums_obj = pl_dict.get("Nums") orelse return null;
            break :blk switch (nums_obj) {
                .array => |a| a,
                .reference => |r| inner: {
                    const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch return null;
                    break :inner switch (obj) {
                        .array => |a| a,
                        else => return null,
                    };
                },
                else => return null,
            };
        };

        // Find the applicable range entry for page_idx
        // /Nums is [key1 value1 key2 value2 ...] sorted by key
        var best_start: ?usize = null;
        var best_label_dict: ?Object.Dict = null;

        var i: usize = 0;
        while (i + 1 < nums_arr.len) : (i += 2) {
            const start = switch (nums_arr[i]) {
                .integer => |n| @as(usize, @intCast(n)),
                else => continue,
            };
            if (start > page_idx) break;

            const label_obj = switch (nums_arr[i + 1]) {
                .dict => |d| d,
                .reference => |r| inner: {
                    const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch continue;
                    break :inner switch (obj) {
                        .dict => |d| d,
                        else => continue,
                    };
                },
                else => continue,
            };
            best_start = start;
            best_label_dict = label_obj;
        }

        const range_start = best_start orelse return null;
        const label_dict = best_label_dict orelse return null;

        // /St (start value, default 1), /S (style), /P (prefix)
        const st: usize = if (label_dict.getInt("St")) |v| @intCast(v) else 1;
        const page_number = st + (page_idx - range_start);
        const style = label_dict.getName("S");
        const prefix = label_dict.getString("P");

        // Format the label
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        if (prefix) |p| {
            buf.appendSlice(allocator, p) catch return null;
        }

        if (style) |s| {
            if (s.len > 0) switch (s[0]) {
                'D' => {
                    // Decimal
                    runtime.arrayListWriter(&buf, allocator).print("{}", .{page_number}) catch return null;
                },
                'r' => {
                    // Lowercase roman
                    formatRoman(&buf, allocator, page_number, false) catch return null;
                },
                'R' => {
                    // Uppercase roman
                    formatRoman(&buf, allocator, page_number, true) catch return null;
                },
                'a' => {
                    // Lowercase alpha
                    formatAlpha(&buf, allocator, page_number, false) catch return null;
                },
                'A' => {
                    // Uppercase alpha
                    formatAlpha(&buf, allocator, page_number, true) catch return null;
                },
                else => {
                    runtime.arrayListWriter(&buf, allocator).print("{}", .{page_number}) catch return null;
                },
            };
        }

        if (buf.items.len == 0) {
            // No style, just return prefix or page number
            if (prefix == null) {
                runtime.arrayListWriter(&buf, allocator).print("{}", .{page_idx + 1}) catch return null;
            }
        }

        return buf.toOwnedSlice(allocator) catch null;
    }

    fn formatRoman(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, number: usize, upper: bool) !void {
        if (number == 0 or number > 3999) {
            try runtime.arrayListWriter(buf, allocator).print("{}", .{number});
            return;
        }
        const values = [_]struct { v: u16, s_upper: []const u8, s_lower: []const u8 }{
            .{ .v = 1000, .s_upper = "M", .s_lower = "m" },
            .{ .v = 900, .s_upper = "CM", .s_lower = "cm" },
            .{ .v = 500, .s_upper = "D", .s_lower = "d" },
            .{ .v = 400, .s_upper = "CD", .s_lower = "cd" },
            .{ .v = 100, .s_upper = "C", .s_lower = "c" },
            .{ .v = 90, .s_upper = "XC", .s_lower = "xc" },
            .{ .v = 50, .s_upper = "L", .s_lower = "l" },
            .{ .v = 40, .s_upper = "XL", .s_lower = "xl" },
            .{ .v = 10, .s_upper = "X", .s_lower = "x" },
            .{ .v = 9, .s_upper = "IX", .s_lower = "ix" },
            .{ .v = 5, .s_upper = "V", .s_lower = "v" },
            .{ .v = 4, .s_upper = "IV", .s_lower = "iv" },
            .{ .v = 1, .s_upper = "I", .s_lower = "i" },
        };
        var n = number;
        for (values) |entry| {
            while (n >= entry.v) {
                try buf.appendSlice(allocator, if (upper) entry.s_upper else entry.s_lower);
                n -= entry.v;
            }
        }
    }

    fn formatAlpha(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, number: usize, upper: bool) !void {
        if (number == 0) {
            try runtime.arrayListWriter(buf, allocator).print("{}", .{number});
            return;
        }
        // a=1, b=2, ..., z=26, aa=27, ab=28, ...
        var n = number - 1;
        var chars: [8]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const c: u8 = @intCast(n % 26);
            chars[len] = if (upper) 'A' + c else 'a' + c;
            len += 1;
            if (n < 26) break;
            n = n / 26 - 1;
        }
        // Reverse
        var j: usize = 0;
        while (j < len / 2) : (j += 1) {
            const tmp = chars[j];
            chars[j] = chars[len - 1 - j];
            chars[len - 1 - j] = tmp;
        }
        try buf.appendSlice(allocator, chars[0..len]);
    }

    // =========================================================================
    // Feature 4: Text Search
    // =========================================================================

    pub const SearchResult = struct {
        page: usize,
        offset: usize,
        context: []const u8,
    };

    pub const DetailedSearchOptions = struct {
        normalization: text_search.Options = text_search.Options.richDefault(),
        context_radius: usize = 50,
        max_results_per_page: ?usize = null,
    };

    pub const SearchFailureStage = enum(u8) {
        structured_text,
        page_content,
        full_context_text,
        native_geometry,
        native_layout,
    };

    pub const SearchPageFailure = struct {
        page: usize,
        stage: SearchFailureStage,
        error_name: []const u8,
    };

    pub const DetailedSearchMatch = struct {
        page: usize,
        source_kind: text_search.SourceKind,
        /// Byte offset into a caller-reproducible normalized text view.
        /// Native glyph lanes use null because their synthetic views are not
        /// retained after searchDetailed returns.
        normalized_offset: ?usize,
        /// Byte offsets into a caller-reproducible text view. Native glyph
        /// lanes use null and expose glyph indices as their stable locator.
        source_start: ?usize,
        source_end: ?usize,
        context: []u8,
        /// Sorted, unique glyph ids contributing to a native match. This is
        /// the exact stable locator; first/last remain a compatibility envelope.
        glyph_indices: []u32 = &.{},
        first_glyph_index: ?u32 = null,
        last_glyph_index: ?u32 = null,
        bbox: ?layout.BBox = null,
        transformations: u32 = 0,
    };

    pub const SearchReport = struct {
        allocator: std.mem.Allocator,
        matches: []DetailedSearchMatch,
        page_failures: []SearchPageFailure,
        pages_searched: usize,

        pub fn deinit(self: *SearchReport) void {
            for (self.matches) |match| {
                self.allocator.free(match.context);
                self.allocator.free(match.glyph_indices);
            }
            self.allocator.free(self.matches);
            self.allocator.free(self.page_failures);
            self.* = undefined;
        }
    };

    /// Rich normalized search with explicit source provenance and page failures.
    ///
    /// Each page unions matches from all available source views. Matches are
    /// deduplicated only when page-view identity, exact glyph evidence, or
    /// matching local context identifies the same occurrence.
    pub fn searchDetailed(
        self: *Document,
        allocator: std.mem.Allocator,
        query: []const u8,
        options: DetailedSearchOptions,
    ) !SearchReport {
        const normalized_query = try text_search.normalizeQuery(allocator, query, options.normalization);
        defer allocator.free(normalized_query);

        var matches: std.ArrayList(DetailedSearchMatch) = .empty;
        errdefer {
            freeDetailedSearchMatches(allocator, matches.items);
            matches.deinit(allocator);
        }
        var failures: std.ArrayList(SearchPageFailure) = .empty;
        errdefer failures.deinit(allocator);

        if (normalized_query.len == 0) {
            return finishSearchReport(
                allocator,
                &matches,
                &failures,
                self.pages.items.len,
            );
        }

        for (0..self.pages.items.len) |page_idx| {
            var page_candidates: [4]std.ArrayList(SearchCandidate) = @splat(.empty);
            defer {
                for (&page_candidates) |*candidate_list| {
                    freeSearchCandidates(allocator, candidate_list.items);
                    candidate_list.deinit(allocator);
                }
            }

            const structured = self.extractTextStructured(page_idx, allocator) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                try failures.append(allocator, .{
                    .page = page_idx,
                    .stage = .structured_text,
                    .error_name = @errorName(err),
                });
                break :blk null;
            };
            if (structured) |source_text| {
                defer allocator.free(source_text);
                var view = try text_search.buildView(
                    allocator,
                    source_text,
                    .legacy_structured,
                    options.normalization,
                    &.{},
                );
                defer view.deinit();
                try collectViewMatches(
                    allocator,
                    page_idx,
                    &view,
                    normalized_query,
                    options,
                    &page_candidates[0],
                );
            }

            var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch_arena.deinit();
            const scratch_allocator = scratch_arena.allocator();
            const content = self.getPageContentForScratch(page_idx, scratch_allocator) catch |err| {
                if (err == error.OutOfMemory) return err;
                try failures.append(allocator, .{
                    .page = page_idx,
                    .stage = .page_content,
                    .error_name = @errorName(err),
                });
                try appendUniqueCandidates(
                    allocator,
                    &matches,
                    &page_candidates,
                    options.max_results_per_page,
                );
                continue;
            };

            const raw = self.extractTextFullContextFromContent(
                page_idx,
                allocator,
                scratch_allocator,
                content,
                null,
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                try failures.append(allocator, .{
                    .page = page_idx,
                    .stage = .full_context_text,
                    .error_name = @errorName(err),
                });
                break :blk null;
            };
            defer if (raw) |source_text| allocator.free(source_text);
            if (raw) |source_text| {
                var view = try text_search.buildView(
                    allocator,
                    source_text,
                    .full_context_text,
                    options.normalization,
                    &.{},
                );
                defer view.deinit();
                try collectViewMatches(
                    allocator,
                    page_idx,
                    &view,
                    normalized_query,
                    options,
                    &page_candidates[1],
                );
            }

            var geometry = self.extractNativePageGeometryFromContent(
                page_idx,
                allocator,
                scratch_allocator,
                content,
            ) catch |err| blk: {
                if (err == error.OutOfMemory) return err;
                try failures.append(allocator, .{
                    .page = page_idx,
                    .stage = .native_geometry,
                    .error_name = @errorName(err),
                });
                break :blk null;
            };
            if (geometry) |*native_geometry| {
                defer native_geometry.deinit();
                const canonical_glyphs = native_geometry.semantic_glyphs orelse native_geometry.glyphs;
                const raw_or_empty: []const u8 = if (raw) |raw_text| raw_text else "";
                const page = self.pages.items[page_idx];
                var native_result = native_layout.analyze(
                    allocator,
                    canonical_glyphs,
                    .{
                        .x0 = page.media_box[0],
                        .y0 = page.media_box[1],
                        .x1 = page.media_box[2],
                        .y1 = page.media_box[3],
                    },
                    raw_or_empty,
                ) catch |err| blk: {
                    if (err == error.OutOfMemory) return err;
                    try failures.append(allocator, .{
                        .page = page_idx,
                        .stage = .native_layout,
                        .error_name = @errorName(err),
                    });
                    break :blk null;
                };
                if (native_result) |*result| {
                    defer result.deinit();
                    var reading_source = try buildGlyphSearchSource(
                        allocator,
                        canonical_glyphs,
                        result.ordered_glyph_indices,
                        result.boundaries,
                    );
                    defer reading_source.deinit();
                    var reading_view = try text_search.buildView(
                        allocator,
                        reading_source.text,
                        .native_reading,
                        options.normalization,
                        reading_source.evidence,
                    );
                    defer reading_view.deinit();
                    try collectViewMatches(
                        allocator,
                        page_idx,
                        &reading_view,
                        normalized_query,
                        options,
                        &page_candidates[2],
                    );
                }

                var content_source = try buildGlyphSearchSource(
                    allocator,
                    canonical_glyphs,
                    null,
                    null,
                );
                defer content_source.deinit();
                var content_view = try text_search.buildView(
                    allocator,
                    content_source.text,
                    .native_content,
                    options.normalization,
                    content_source.evidence,
                );
                defer content_view.deinit();
                try collectViewMatches(
                    allocator,
                    page_idx,
                    &content_view,
                    normalized_query,
                    options,
                    &page_candidates[3],
                );
            }

            try appendUniqueCandidates(
                allocator,
                &matches,
                &page_candidates,
                options.max_results_per_page,
            );
        }

        return finishSearchReport(
            allocator,
            &matches,
            &failures,
            self.pages.items.len,
        );
    }

    /// Search for text across all pages. Returns matches with page, offset, and context.
    /// Caller must free the returned slice and each context string.
    pub fn search(self: *Document, allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
        if (query.len == 0) return allocator.alloc(SearchResult, 0);

        var results: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (results.items) |r| {
                allocator.free(r.context);
            }
            results.deinit(allocator);
        }

        // Lowercase query for case-insensitive search
        const query_lower = try allocator.alloc(u8, query.len);
        defer allocator.free(query_lower);
        for (query, 0..) |c, idx| {
            query_lower[idx] = asciiToLower(c);
        }

        for (0..self.pages.items.len) |page_idx| {
            const page_text = self.extractTextStructured(page_idx, allocator) catch continue;
            defer allocator.free(page_text);

            if (page_text.len == 0) continue;

            // Lowercase page text for comparison
            const text_lower = try allocator.alloc(u8, page_text.len);
            defer allocator.free(text_lower);
            for (page_text, 0..) |c, idx| {
                text_lower[idx] = asciiToLower(c);
            }

            // Find all occurrences
            var pos: usize = 0;
            while (pos + query_lower.len <= text_lower.len) {
                if (std.mem.indexOf(u8, text_lower[pos..], query_lower)) |match_offset| {
                    const abs_offset = pos + match_offset;

                    // Build context snippet (~50 chars before/after)
                    const ctx_start = if (abs_offset > 50) abs_offset - 50 else 0;
                    const ctx_end = @min(abs_offset + query.len + 50, page_text.len);
                    try results.ensureUnusedCapacity(allocator, 1);
                    const context = try allocator.dupe(u8, page_text[ctx_start..ctx_end]);

                    results.appendAssumeCapacity(.{
                        .page = page_idx,
                        .offset = abs_offset,
                        .context = context,
                    });

                    pos = abs_offset + query_lower.len;
                } else break;
            }
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn freeSearchResults(allocator: std.mem.Allocator, results: []SearchResult) void {
        for (results) |r| {
            allocator.free(r.context);
        }
        allocator.free(results);
    }

    fn asciiToLower(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    const search_anchor_radius = 32;
    const search_position_scale: u32 = 1_000_000;

    const SearchCandidate = struct {
        match: DetailedSearchMatch,
        normalized_source_hash: u64,
        normalized_source_len: usize,
        normalized_page_offset: usize,
        page_position: u32,
        glyph_identity_hash: ?u64 = null,
        left_anchor: [search_anchor_radius]u8 = @splat(0),
        left_anchor_len: u8 = 0,
        right_anchor: [search_anchor_radius]u8 = @splat(0),
        right_anchor_len: u8 = 0,
        duplicate_ordinal: usize = 0,
    };

    const GlyphSearchSource = struct {
        allocator: std.mem.Allocator,
        text: []u8,
        evidence: []text_search.SourceEvidence,

        fn deinit(self: *GlyphSearchSource) void {
            self.allocator.free(self.text);
            self.allocator.free(self.evidence);
            self.* = undefined;
        }
    };

    fn buildGlyphSearchSource(
        allocator: std.mem.Allocator,
        glyphs: []const GlyphSpan,
        ordered_indices: ?[]const u32,
        boundaries: ?[]const native_layout.Boundary,
    ) !GlyphSearchSource {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(allocator);
        var evidence: std.ArrayList(text_search.SourceEvidence) = .empty;
        errdefer evidence.deinit(allocator);

        const count = if (ordered_indices) |ordered| ordered.len else glyphs.len;
        for (0..count) |ordered_index| {
            const glyph_index: u32 = if (ordered_indices) |ordered|
                ordered[ordered_index]
            else
                @intCast(ordered_index);
            if (boundaries) |items| {
                if (ordered_index > 0) switch (items[ordered_index].kind) {
                    .join => {},
                    .space => if (text.items.len == 0 or !std.ascii.isWhitespace(text.items[text.items.len - 1])) {
                        try text.append(allocator, ' ');
                    },
                    .line_break => try text.append(allocator, '\n'),
                    .block_break, .region_break => {
                        try text.append(allocator, '\n');
                        try text.append(allocator, '\n');
                    },
                };
            }
            const glyph = glyphs[glyph_index];
            if (glyph.text.len == 0) continue;
            const source_start = text.items.len;
            try text.appendSlice(allocator, glyph.text);
            try evidence.append(allocator, .{
                .source_start = source_start,
                .source_end = text.items.len,
                .glyph_index = if (glyph.semantic_replacement) null else glyph.raw_glyph_start orelse glyph_index,
                .bbox = glyph.bbox,
            });
        }

        const owned_text = try text.toOwnedSlice(allocator);
        errdefer allocator.free(owned_text);
        const owned_evidence = try evidence.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .text = owned_text,
            .evidence = owned_evidence,
        };
    }

    fn collectViewMatches(
        allocator: std.mem.Allocator,
        page_idx: usize,
        view: *const text_search.SearchTextView,
        normalized_query: []const u8,
        options: DetailedSearchOptions,
        output: *std.ArrayList(SearchCandidate),
    ) !void {
        const locations = try view.findAll(
            allocator,
            normalized_query,
            options.max_results_per_page,
        );
        defer allocator.free(locations);
        const normalized_source_hash = std.hash.Wyhash.hash(0, view.normalized_text);
        for (locations, 0..) |location, occurrence_ordinal| {
            const bounds = text_search.contextBounds(
                view.source_text,
                location.source.source_start,
                location.source.source_end,
                options.context_radius,
            );
            const context = try allocator.dupe(u8, view.source_text[bounds.start..bounds.end]);
            errdefer allocator.free(context);
            const glyph_identity = try view.glyphIdentity(
                allocator,
                location.source.source_start,
                location.source.source_end,
            );
            errdefer allocator.free(glyph_identity);

            var candidate = SearchCandidate{
                .match = .{
                    .page = page_idx,
                    .source_kind = view.source_kind,
                    .normalized_offset = if (sourceOffsetsAreStable(view.source_kind))
                        location.normalized_start
                    else
                        null,
                    .source_start = if (sourceOffsetsAreStable(view.source_kind))
                        location.source.source_start
                    else
                        null,
                    .source_end = if (sourceOffsetsAreStable(view.source_kind))
                        location.source.source_end
                    else
                        null,
                    .context = context,
                    .glyph_indices = glyph_identity,
                    .first_glyph_index = location.source.first_glyph_index,
                    .last_glyph_index = location.source.last_glyph_index,
                    .bbox = location.source.bbox,
                    .transformations = location.source.transformations,
                },
                .normalized_source_hash = normalized_source_hash,
                .normalized_source_len = view.normalized_text.len,
                .normalized_page_offset = location.normalized_start,
                .page_position = normalizedPagePosition(
                    location.normalized_start,
                    view.normalized_text.len,
                ),
                .glyph_identity_hash = if (glyph_identity.len > 0)
                    std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(glyph_identity))
                else
                    null,
                .duplicate_ordinal = occurrence_ordinal,
            };
            fillSearchAnchors(&candidate, view.normalized_text, location);
            try output.append(allocator, candidate);
        }
    }

    fn appendUniqueCandidates(
        allocator: std.mem.Allocator,
        output: *std.ArrayList(DetailedSearchMatch),
        candidate_lists: *[4]std.ArrayList(SearchCandidate),
        max_results: ?usize,
    ) !void {
        var flat_candidates: std.ArrayList(*const SearchCandidate) = .empty;
        defer flat_candidates.deinit(allocator);
        var lane_starts: [4]usize = @splat(0);
        var lane_lengths: [4]usize = @splat(0);
        for (candidate_lists, 0..) |*candidate_list, lane_index| {
            lane_starts[lane_index] = flat_candidates.items.len;
            lane_lengths[lane_index] = candidate_list.items.len;
            for (candidate_list.items) |*candidate| {
                try flat_candidates.append(allocator, candidate);
            }
        }

        const parents = try allocator.alloc(usize, flat_candidates.items.len);
        defer allocator.free(parents);
        for (parents, 0..) |*parent, index| parent.* = index;

        var glyph_groups = std.AutoHashMap(u64, usize).init(allocator);
        defer glyph_groups.deinit();
        for (candidate_lists, 0..) |*candidate_list, lane_index| {
            for (candidate_list.items, 0..) |*candidate, occurrence_ordinal| {
                const candidate_index = lane_starts[lane_index] + occurrence_ordinal;
                if (candidate.glyph_identity_hash) |identity_hash| {
                    if (glyph_groups.get(identity_hash)) |existing_index| {
                        const existing = flat_candidates.items[existing_index];
                        if (std.mem.eql(u32, candidate.match.glyph_indices, existing.match.glyph_indices)) {
                            searchUnion(parents, candidate_index, existing_index);
                        }
                    } else {
                        try glyph_groups.put(identity_hash, candidate_index);
                    }
                }
                for (0..lane_index) |prior_lane| {
                    if (occurrence_ordinal >= lane_lengths[prior_lane]) continue;
                    const existing_index = lane_starts[prior_lane] + occurrence_ordinal;
                    if (samePhysicalSearchMatch(candidate, flat_candidates.items[existing_index])) {
                        searchUnion(parents, candidate_index, existing_index);
                    }
                }
            }
        }

        var representatives = std.AutoHashMap(usize, usize).init(allocator);
        defer representatives.deinit();
        for (flat_candidates.items, 0..) |candidate, candidate_index| {
            const root_index = searchFind(parents, candidate_index);
            const entry = try representatives.getOrPut(root_index);
            if (!entry.found_existing or
                preferSearchCandidate(candidate, flat_candidates.items[entry.value_ptr.*]))
            {
                entry.value_ptr.* = candidate_index;
            }
        }

        var selected: std.ArrayList(*const SearchCandidate) = .empty;
        defer selected.deinit(allocator);
        for (flat_candidates.items, 0..) |candidate, candidate_index| {
            const root_index = searchFind(parents, candidate_index);
            if (representatives.get(root_index).? == candidate_index) {
                try selected.append(allocator, candidate);
            }
        }
        std.mem.sort(*const SearchCandidate, selected.items, {}, searchCandidateLessThan);

        const result_count = if (max_results) |limit|
            @min(limit, selected.items.len)
        else
            selected.items.len;
        for (selected.items[0..result_count]) |candidate| {
            const context = try allocator.dupe(u8, candidate.match.context);
            errdefer allocator.free(context);
            const glyph_indices = try allocator.dupe(u32, candidate.match.glyph_indices);
            errdefer allocator.free(glyph_indices);
            var owned = candidate.match;
            owned.context = context;
            owned.glyph_indices = glyph_indices;
            try output.append(allocator, owned);
        }
    }

    fn searchFind(parents: []usize, start_index: usize) usize {
        var root_index = start_index;
        while (parents[root_index] != root_index) root_index = parents[root_index];
        var index = start_index;
        while (parents[index] != index) {
            const next_index = parents[index];
            parents[index] = root_index;
            index = next_index;
        }
        return root_index;
    }

    fn searchUnion(parents: []usize, a_index: usize, b_index: usize) void {
        const a_root = searchFind(parents, a_index);
        const b_root = searchFind(parents, b_index);
        if (a_root != b_root) parents[b_root] = a_root;
    }

    fn normalizedPagePosition(normalized_offset: usize, normalized_length: usize) u32 {
        if (normalized_length == 0) return 0;
        const scaled: u128 = @as(u128, normalized_offset) * search_position_scale;
        return @intCast(@min(scaled / normalized_length, search_position_scale));
    }

    fn fillSearchAnchors(
        candidate: *SearchCandidate,
        normalized_text: []const u8,
        location: text_search.MatchLocation,
    ) void {
        const left_start = location.normalized_start -| search_anchor_radius;
        const left = normalized_text[left_start..location.normalized_start];
        @memcpy(candidate.left_anchor[0..left.len], left);
        candidate.left_anchor_len = @intCast(left.len);

        const right_end = @min(
            normalized_text.len,
            location.normalized_end +| search_anchor_radius,
        );
        const right = normalized_text[location.normalized_end..right_end];
        @memcpy(candidate.right_anchor[0..right.len], right);
        candidate.right_anchor_len = @intCast(right.len);
    }

    fn samePhysicalSearchMatch(a: *const SearchCandidate, b: *const SearchCandidate) bool {
        if (a.match.page != b.match.page) return false;
        if (a.match.glyph_indices.len > 0 and b.match.glyph_indices.len > 0 and
            a.glyph_identity_hash == b.glyph_identity_hash and
            std.mem.eql(u32, a.match.glyph_indices, b.match.glyph_indices))
        {
            return true;
        }
        if (a.normalized_source_hash == b.normalized_source_hash and
            a.normalized_source_len == b.normalized_source_len and
            a.normalized_page_offset == b.normalized_page_offset)
        {
            return true;
        }
        if (a.duplicate_ordinal != b.duplicate_ordinal) return false;
        return sameSearchAnchor(a, b);
    }

    fn sameSearchAnchor(a: *const SearchCandidate, b: *const SearchCandidate) bool {
        const left_len = @min(@as(u8, 12), @min(a.left_anchor_len, b.left_anchor_len));
        const right_len = @min(@as(u8, 12), @min(a.right_anchor_len, b.right_anchor_len));
        const left_matches = if (left_len >= 8) blk: {
            const a_start = a.left_anchor_len - left_len;
            const b_start = b.left_anchor_len - left_len;
            break :blk std.mem.eql(
                u8,
                a.left_anchor[a_start..a.left_anchor_len],
                b.left_anchor[b_start..b.left_anchor_len],
            );
        } else false;
        const right_matches = right_len >= 8 and std.mem.eql(
            u8,
            a.right_anchor[0..right_len],
            b.right_anchor[0..right_len],
        );
        if (left_len >= 8 and right_len >= 8) return left_matches and right_matches;
        return left_matches or right_matches;
    }

    fn searchCandidateLessThan(
        _: void,
        a: *const SearchCandidate,
        b: *const SearchCandidate,
    ) bool {
        if (a.page_position != b.page_position) return a.page_position < b.page_position;
        if (a.duplicate_ordinal != b.duplicate_ordinal) {
            return a.duplicate_ordinal < b.duplicate_ordinal;
        }
        const a_preference = sourcePreference(a.match.source_kind);
        const b_preference = sourcePreference(b.match.source_kind);
        if (a_preference != b_preference) return a_preference > b_preference;
        if (a.normalized_page_offset != b.normalized_page_offset) {
            return a.normalized_page_offset < b.normalized_page_offset;
        }
        return @backingInt(a.match.source_kind) < @backingInt(b.match.source_kind);
    }

    fn preferSearchCandidate(candidate: *const SearchCandidate, current: *const SearchCandidate) bool {
        if (candidate.match.bbox != null and current.match.bbox == null) return true;
        if (candidate.match.bbox == null and current.match.bbox != null) return false;
        return sourcePreference(candidate.match.source_kind) > sourcePreference(current.match.source_kind);
    }

    fn sourcePreference(source_kind: text_search.SourceKind) u8 {
        return switch (source_kind) {
            .native_reading => 5,
            .native_content => 4,
            .full_context_text => 3,
            .legacy_structured => 2,
            .poppler_text => 1,
        };
    }

    fn sourceOffsetsAreStable(source_kind: text_search.SourceKind) bool {
        return switch (source_kind) {
            .native_reading, .native_content => false,
            .full_context_text, .legacy_structured, .poppler_text => true,
        };
    }

    fn finishSearchReport(
        allocator: std.mem.Allocator,
        matches: *std.ArrayList(DetailedSearchMatch),
        failures: *std.ArrayList(SearchPageFailure),
        pages_searched: usize,
    ) !SearchReport {
        const owned_matches = try matches.toOwnedSlice(allocator);
        errdefer {
            freeDetailedSearchMatches(allocator, owned_matches);
            allocator.free(owned_matches);
        }
        const owned_failures = try failures.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .matches = owned_matches,
            .page_failures = owned_failures,
            .pages_searched = pages_searched,
        };
    }

    fn freeSearchCandidates(allocator: std.mem.Allocator, candidates: []SearchCandidate) void {
        for (candidates) |candidate| {
            allocator.free(candidate.match.context);
            allocator.free(candidate.match.glyph_indices);
        }
    }

    fn freeDetailedSearchMatches(allocator: std.mem.Allocator, matches: []DetailedSearchMatch) void {
        for (matches) |match| {
            allocator.free(match.context);
            allocator.free(match.glyph_indices);
        }
    }

    // =========================================================================
    // Feature 5: Link/Annotation extraction
    // =========================================================================

    pub const Link = struct {
        rect: [4]f64,
        uri: ?[]const u8,
        dest_page: ?usize,
    };

    /// Extract link annotations from a page.
    /// Caller must free the returned slice.
    pub fn getPageLinks(self: *Document, page_idx: usize, allocator: std.mem.Allocator) ![]Link {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        const arena = self.parsing_arena.allocator();
        const page = self.pages.items[page_idx];

        const annots_obj = page.dict.get("Annots") orelse return allocator.alloc(Link, 0);

        const annots_arr = switch (annots_obj) {
            .array => |a| a,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch
                    return allocator.alloc(Link, 0);
                break :blk switch (obj) {
                    .array => |a| a,
                    else => return allocator.alloc(Link, 0),
                };
            },
            else => return allocator.alloc(Link, 0),
        };

        var links: std.ArrayList(Link) = .empty;
        errdefer {
            for (links.items) |link| {
                if (link.uri) |u| allocator.free(u);
            }
            links.deinit(allocator);
        }

        for (annots_arr) |annot_obj| {
            const annot_dict = switch (annot_obj) {
                .dict => |d| d,
                .reference => |r| blk: {
                    const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch continue;
                    break :blk switch (obj) {
                        .dict => |d| d,
                        else => continue,
                    };
                },
                else => continue,
            };

            // Only process /Link annotations
            const subtype = annot_dict.getName("Subtype") orelse continue;
            if (!std.mem.eql(u8, subtype, "Link")) continue;

            // Parse /Rect
            const rect = parseRect(annot_dict) orelse continue;

            // Try /A (action dict) first
            var uri: ?[]const u8 = null;
            var dest_page: ?usize = null;

            if (annot_dict.get("A")) |action_obj| {
                const action = switch (action_obj) {
                    .dict => |d| d,
                    .reference => |r| blk: {
                        const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch null;
                        break :blk if (obj) |o| switch (o) {
                            .dict => |d| d,
                            else => null,
                        } else null;
                    },
                    else => null,
                };

                if (action) |act| {
                    const action_type = act.getName("S");
                    if (action_type) |s| {
                        if (std.mem.eql(u8, s, "URI")) {
                            if (act.getString("URI")) |u| {
                                uri = try allocator.dupe(u8, u);
                            }
                        } else if (std.mem.eql(u8, s, "GoTo")) {
                            // Internal link
                            if (act.get("D")) |d_obj| {
                                dest_page = self.resolveDestToPage(d_obj);
                            }
                        }
                    }
                }
            }

            // Try /Dest if no /A
            if (uri == null and dest_page == null) {
                if (annot_dict.get("Dest")) |dest_obj| {
                    dest_page = self.resolveDestToPage(dest_obj);
                }
            }

            try links.append(allocator, .{
                .rect = rect,
                .uri = uri,
                .dest_page = dest_page,
            });
        }

        return links.toOwnedSlice(allocator);
    }

    pub fn freeLinks(allocator: std.mem.Allocator, links: []Link) void {
        for (links) |link| {
            if (link.uri) |u| allocator.free(u);
        }
        allocator.free(links);
    }

    fn parseRect(dict: Object.Dict) ?[4]f64 {
        const rect_arr = dict.getArray("Rect") orelse return null;
        if (rect_arr.len < 4) return null;
        return .{
            objToF64(rect_arr[0]) orelse return null,
            objToF64(rect_arr[1]) orelse return null,
            objToF64(rect_arr[2]) orelse return null,
            objToF64(rect_arr[3]) orelse return null,
        };
    }

    fn objToF64(obj: Object) ?f64 {
        return switch (obj) {
            .real => |r| r,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    fn resolveDestToPage(self: *Document, dest_obj: Object) ?usize {
        const arena = self.parsing_arena.allocator();
        // Destination can be an array [page_ref /Fit ...] or a name (named dest)
        const arr = switch (dest_obj) {
            .array => |a| a,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch return null;
                break :blk switch (obj) {
                    .array => |a| a,
                    else => return null,
                };
            },
            else => return null,
        };
        if (arr.len == 0) return null;

        // First element should be a page reference
        const page_ref = switch (arr[0]) {
            .reference => |r| r,
            else => return null,
        };

        // Match against our page list
        for (self.pages.items, 0..) |p, idx| {
            if (p.ref.eql(page_ref)) return idx;
        }
        return null;
    }

    /// Rasterize one routed formula region to an ephemeral PNG. The crop is
    /// page-clamped and expressed in Poppler's top-left pixel coordinates.
    /// Quarter-turn pages use the shared page transform; the legacy requested
    /// bbox is retained alongside the crop-local pixel-to-PDF mapping.
    pub fn rasterizeFormulaRegionDetailed(
        self: *Document,
        allocator: std.mem.Allocator,
        page_idx: usize,
        bbox: layout.BBox,
        config: specialists.SpecialistConfig,
    ) !specialists.FormulaCropOutcome {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;
        const source_path = self.source_path orelse return .{
            .status = .unavailable,
            .diagnostic_code = "formula_crop_requires_file",
        };
        const page = self.pages.items[page_idx];
        const page_model = self.getPageGeometry(page_idx) orelse return .{
            .status = .unavailable,
            .diagnostic_code = if (@mod(page.rotation, 90) != 0) "formula_crop_rotation_unsupported" else "invalid_formula_crop_geometry",
        };
        const geometry = page_model.planCrop(bbox, .{ .padding_points = config.crop_padding_points, .dpi = @floatFromInt(config.crop_dpi) }) catch return .{
            .status = .invalid_output,
            .diagnostic_code = "invalid_formula_crop_geometry",
        };
        const raster_limits = ocr.OcrConfig{};
        if (!@import("ocr/crop.zig").withinPixelLimit(geometry.width, geometry.height, raster_limits.max_image_pixels)) return .{
            .status = .invalid_output,
            .diagnostic_code = "formula_crop_pixel_limit",
        };

        const page_number = try std.fmt.allocPrint(allocator, "{}", .{page_idx + 1});
        defer allocator.free(page_number);
        const dpi_arg = try std.fmt.allocPrint(allocator, "{d}", .{geometry.rasterizer_dpi});
        defer allocator.free(dpi_arg);
        const x_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.x});
        defer allocator.free(x_arg);
        const y_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.y});
        defer allocator.free(y_arg);
        const width_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.width});
        defer allocator.free(width_arg);
        const height_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.height});
        defer allocator.free(height_arg);

        const filename = try std.fmt.allocPrint(allocator, "pdf-parser-formula-crop-{x}-{x}", .{ page_idx, runtime.nanoTimestamp() });
        defer allocator.free(filename);
        const temp_dir: []const u8 = if (builtin.target.os.tag == .windows) "." else "/tmp";
        const prefix = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        defer allocator.free(prefix);
        const image_path = try std.fmt.allocPrint(allocator, "{s}.png", .{prefix});
        var keep_image_path = false;
        defer if (!keep_image_path) {
            runtime.deleteFilePath(image_path);
            allocator.free(image_path);
        };

        const grayscale_argv = [_][]const u8{
            config.rasterizer_executable, "-q",        "-png",    "-gray",     "-singlefile", "-r",        dpi_arg,
            "-f",                         page_number, "-l",      page_number, "-x",          x_arg,       "-y",
            y_arg,                        "-W",        width_arg, "-H",        height_arg,    source_path, prefix,
        };
        const color_argv = [_][]const u8{
            config.rasterizer_executable, "-q",        "-png", "-singlefile", "-r", dpi_arg,
            "-f",                         page_number, "-l",   page_number,   "-x", x_arg,
            "-y",                         y_arg,       "-W",   width_arg,     "-H", height_arg,
            source_path,                  prefix,
        };
        const argv = if (config.crop_grayscale) &grayscale_argv else &color_argv;
        const started_ns = runtime.nanoTimestamp();
        const result = runtime.runCapture(allocator, argv, .{
            .stdout_limit = 64 * 1024,
            .stderr_limit = config.stderr_limit,
            .timeout_ms = config.timeout_ms,
        }) catch |err| switch (err) {
            error.FileNotFound => return .{
                .status = .unavailable,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = "formula_rasterizer_unavailable",
            },
            error.Timeout => return .{
                .status = .timeout,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = "formula_rasterizer_timeout",
            },
            error.StreamTooLong => return .{
                .status = .invalid_output,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = "formula_rasterizer_output_limit",
            },
            else => return err,
        };
        defer allocator.free(result.stdout);
        errdefer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return .{
                .status = .failed,
                .exit_code = code,
                .stderr = result.stderr,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = "formula_rasterizer_failed",
            },
            else => return .{
                .status = .failed,
                .stderr = result.stderr,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = "formula_rasterizer_failed",
            },
        }
        const dimensions = @import("ocr/crop.zig").readIdentity(allocator, image_path, raster_limits.max_image_bytes, raster_limits.max_image_pixels) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{
                .status = .invalid_output,
                .stderr = result.stderr,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = "invalid_formula_crop_image",
            },
        };
        if (dimensions.width != geometry.width or dimensions.height != geometry.height) return .{
            .status = .invalid_output,
            .stderr = result.stderr,
            .duration_ms = elapsedMilliseconds(started_ns),
            .diagnostic_code = "invalid_formula_crop_image",
        };
        keep_image_path = true;
        return .{
            .status = .completed,
            .input = .{
                .image_path = image_path,
                .pdf_bbox = geometry.clamped_bbox,
                .pixel_to_pdf = geometry.pixel_to_pdf,
                .rasterizer_dpi = geometry.rasterizer_dpi,
                .pixel_width = dimensions.width,
                .pixel_height = dimensions.height,
                .dpi = config.crop_dpi,
            },
            .stderr = result.stderr,
            .duration_ms = elapsedMilliseconds(started_ns),
        };
    }

    const FormulaCropGeometry = struct {
        pdf_bbox: layout.BBox,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    };

    fn formulaCropGeometry(page_bbox: layout.BBox, bbox: layout.BBox, padding: f64, dpi: u32) ?FormulaCropGeometry {
        const model = page_geometry.PageGeometry.init(page_bbox, page_bbox, 0, 1) catch return null;
        const plan = model.planCrop(bbox, .{ .padding_points = padding, .dpi = @floatFromInt(dpi) }) catch return null;
        return .{
            .pdf_bbox = plan.clamped_bbox,
            .x = plan.x,
            .y = plan.y,
            .width = plan.width,
            .height = plan.height,
        };
    }

    /// Rasterize a page to a temporary PNG for an OCR engine.
    /// Returns null for memory-opened documents because subprocess rasterizers
    /// need a filesystem PDF path. Caller owns `image_path` and should delete it.
    pub fn rasterizePageForOcr(self: *Document, allocator: std.mem.Allocator, page_idx: usize, config: ocr.OcrConfig) !?ocr.OcrInput {
        var outcome = try self.rasterizePageForOcrDetailed(allocator, page_idx, config);
        defer outcome.deinit(allocator);
        return switch (outcome.status) {
            .completed => {
                const input = outcome.input;
                outcome.input = null;
                return input;
            },
            .not_invoked => null,
            .unavailable => error.OcrRasterizerUnavailable,
            .timeout => error.OcrRasterizerTimeout,
            .invalid_output => error.InvalidRasterImage,
            .failed => error.OcrRasterizerFailed,
            .empty => error.InvalidRasterImage,
        };
    }

    pub fn rasterizePageForOcrDetailed(self: *Document, allocator: std.mem.Allocator, page_idx: usize, config: ocr.OcrConfig) !ocr.RasterizeOutcome {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;
        const page = self.pages.items[page_idx];
        return self.rasterizeOcrDetailed(allocator, page_idx, .{ .x0 = page.media_box[0], .y0 = page.media_box[1], .x1 = page.media_box[2], .y1 = page.media_box[3] }, config, false);
    }

    /// Caller owns the ephemeral image path and must delete and free it after
    /// recognition. Quarter-turn mapping uses validated page geometry. Limits
    /// bound accepted raster pixels/bytes, not process RSS.
    pub fn rasterizeOcrRegionDetailed(self: *Document, allocator: std.mem.Allocator, page_idx: usize, bbox: layout.BBox, config: ocr.OcrConfig) !ocr.RasterizeOutcome {
        return self.rasterizeOcrDetailed(allocator, page_idx, bbox, config, true);
    }

    fn rasterizeOcrDetailed(self: *Document, allocator: std.mem.Allocator, page_idx: usize, bbox: layout.BBox, config: ocr.OcrConfig, regional: bool) !ocr.RasterizeOutcome {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;
        const source_path = self.source_path orelse return .{
            .status = .unavailable,
            .diagnostic_code = .rasterizer_requires_file,
        };

        const page = self.pages.items[page_idx];
        const crop = @import("ocr/crop.zig");
        const page_bbox = layout.BBox{ .x0 = page.media_box[0], .y0 = page.media_box[1], .x1 = page.media_box[2], .y1 = page.media_box[3] };
        const page_model = self.getPageGeometry(page_idx) orelse return .{
            .status = .unavailable,
            .diagnostic_code = if (@mod(page.rotation, 90) != 0) .rasterizer_rotation_unsupported else .invalid_crop_geometry,
        };
        const geometry = page_model.planCrop(bbox, .{ .padding_points = if (regional) config.crop_padding_points else 0, .dpi = @floatFromInt(config.dpi) }) catch |err| return .{
            .status = .invalid_output,
            .diagnostic_code = if (err == error.RasterExtentOverflow) .rasterizer_pixel_limit else .invalid_crop_geometry,
        };
        if (!crop.withinPixelLimit(geometry.width, geometry.height, config.max_image_pixels)) return .{ .status = .invalid_output, .diagnostic_code = .rasterizer_pixel_limit };
        if (config.max_image_bytes < 24) return .{ .status = .invalid_output, .diagnostic_code = .rasterizer_image_byte_limit };

        const page_number = try std.fmt.allocPrint(allocator, "{}", .{page_idx + 1});
        defer allocator.free(page_number);

        const dpi_arg = try std.fmt.allocPrint(allocator, "{d}", .{geometry.rasterizer_dpi});
        defer allocator.free(dpi_arg);
        const x_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.x});
        defer allocator.free(x_arg);
        const y_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.y});
        defer allocator.free(y_arg);
        const width_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.width});
        defer allocator.free(width_arg);
        const height_arg = try std.fmt.allocPrint(allocator, "{}", .{geometry.height});
        defer allocator.free(height_arg);

        const prefix = try std.fmt.allocPrint(allocator, ".pdf-parser-ocr-{x}-{x}", .{
            page_idx,
            runtime.nanoTimestamp(),
        });
        defer allocator.free(prefix);

        const image_path = try std.fmt.allocPrint(allocator, "{s}.png", .{prefix});
        var keep_image_path = false;
        defer if (!keep_image_path) {
            runtime.deleteFileCwd(image_path);
            allocator.free(image_path);
        };

        const grayscale_argv = [_][]const u8{
            config.rasterizer_executable,
            "-q",
            "-png",
            "-gray",
            "-singlefile",
            "-r",
            dpi_arg,
            "-f",
            page_number,
            "-l",
            page_number,
            "-x",
            x_arg,
            "-y",
            y_arg,
            "-W",
            width_arg,
            "-H",
            height_arg,
            source_path,
            prefix,
        };
        const color_argv = [_][]const u8{
            config.rasterizer_executable,
            "-q",
            "-png",
            "-singlefile",
            "-r",
            dpi_arg,
            "-f",
            page_number,
            "-l",
            page_number,
            "-x",
            x_arg,
            "-y",
            y_arg,
            "-W",
            width_arg,
            "-H",
            height_arg,
            source_path,
            prefix,
        };
        const argv = if (config.rasterize_grayscale) &grayscale_argv else &color_argv;

        const started_ns = runtime.nanoTimestamp();
        const result = runtime.runCapture(allocator, argv, .{
            .stdout_limit = 64 * 1024,
            .stderr_limit = config.stderr_limit,
            .timeout_ms = config.timeout_ms,
        }) catch |err| switch (err) {
            error.FileNotFound => return .{
                .status = .unavailable,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = .rasterizer_unavailable,
            },
            error.Timeout => return .{
                .status = .timeout,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = .rasterizer_timeout,
            },
            error.StreamTooLong => return .{
                .status = .invalid_output,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = .rasterizer_output_limit,
            },
            else => return err,
        };
        defer allocator.free(result.stdout);
        errdefer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                return .{
                    .status = .failed,
                    .exit_code = code,
                    .stderr = result.stderr,
                    .duration_ms = elapsedMilliseconds(started_ns),
                    .diagnostic_code = .rasterizer_failed,
                };
            },
            else => return .{
                .status = .failed,
                .stderr = result.stderr,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = .rasterizer_failed,
            },
        }

        const dimensions = crop.readIdentity(allocator, image_path, config.max_image_bytes, config.max_image_pixels) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return .{
                .status = .invalid_output,
                .stderr = result.stderr,
                .duration_ms = elapsedMilliseconds(started_ns),
                .diagnostic_code = switch (err) {
                    error.ImageByteLimitExceeded => .rasterizer_image_byte_limit,
                    error.ImagePixelLimitExceeded => .rasterizer_pixel_limit,
                    else => .invalid_raster_image,
                },
            },
        };
        if (dimensions.width != geometry.width or dimensions.height != geometry.height) return .{ .status = .invalid_output, .stderr = result.stderr, .duration_ms = elapsedMilliseconds(started_ns), .diagnostic_code = .invalid_raster_image };
        const pixel_to_pdf = if (regional) geometry.pixel_to_pdf else page_model.fullPagePixelToPdf(.media, dimensions.width, dimensions.height) catch return .{
            .status = .invalid_output,
            .stderr = result.stderr,
            .duration_ms = elapsedMilliseconds(started_ns),
            .diagnostic_code = .invalid_raster_image,
        };
        keep_image_path = true;
        return .{
            .status = .completed,
            .input = .{
                .page_index = @intCast(page_idx),
                // Preserve the established full-page OCR mapping. Regional
                // crops map through their actual outward pixel boundaries.
                .pdf_bbox = if (regional) geometry.pdf_bbox else page_bbox,
                .pixel_to_pdf = pixel_to_pdf,
                .rasterizer_dpi = geometry.rasterizer_dpi,
                .image_path = image_path,
                .pixel_width = dimensions.width,
                .pixel_height = dimensions.height,
                .image_sha256 = dimensions.sha256,
                .image_byte_length = dimensions.byte_length,
            },
            .stderr = result.stderr,
            .duration_ms = elapsedMilliseconds(started_ns),
        };
    }

    fn elapsedMilliseconds(started_ns: i128) u64 {
        const elapsed_ns = runtime.nanoTimestamp() - started_ns;
        return if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1_000_000)) else 0;
    }

    // =========================================================================
    // Feature 6: Image Detection
    // =========================================================================

    pub const ImageInfo = struct {
        rect: [4]f64,
        width: u32,
        height: u32,
    };

    /// Detect images on a page and report their positions and dimensions.
    /// Caller must free the returned slice.
    pub fn getPageImages(self: *Document, page_idx: usize, allocator: std.mem.Allocator) ![]ImageInfo {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = self.getPageContentForScratch(page_idx, scratch_allocator) catch return allocator.alloc(ImageInfo, 0);
        return self.getPageImagesFromContent(page_idx, allocator, scratch_allocator, content);
    }

    /// Detect images from already-decoded page content.
    /// Painted vector-path inventory, independent of text and image extraction.
    pub fn getPageVectorEvidenceFromContent(self: *Document, page_idx: usize, allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, content: []const u8) !vector_evidence.Evidence {
        return self.getPageVectorEvidenceFromContentWithLimits(page_idx, allocator, scratch_allocator, content, .{});
    }

    pub fn getPageVectorEvidenceFromContentWithLimits(self: *Document, page_idx: usize, allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, content: []const u8, limits: vector_evidence.Limits) !vector_evidence.Evidence {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;
        var builder = vector_evidence.Builder{ .allocator = allocator, .limits = limits };
        defer builder.deinit();
        var traversal = form_scope.Traversal{ .page_index = @intCast(page_idx), .max_invocations = limits.max_form_invocations };
        const context = self.contentContext(page_idx, scratch_allocator, &traversal);
        try self.collectVectorEvidence(content, &context, &builder, .{});
        return builder.finish();
    }

    fn collectVectorEvidence(self: *Document, content: []const u8, context: *const ExtractionContext, builder: *vector_evidence.Builder, initial: vector_evidence.Graphics) anyerror!void {
        // Bound cumulative input to the additional vector lexer, including
        // repeated Form placements. Earlier PDF decompression is independent.
        if (content.len > builder.limits.max_content_bytes - builder.content_bytes) {
            builder.limited(true);
            return;
        }
        builder.content_bytes += @intCast(content.len);
        var token_arena = std.heap.ArenaAllocator.init(context.scratch_allocator);
        defer token_arena.deinit();
        var lexer = interpreter.ContentLexer.init(token_arena.allocator(), content);
        var operands: [128]interpreter.Operand = undefined;
        var count: usize = 0;
        var collector = vector_evidence.Collector{ .builder = builder, .graphics = initial, .scope = context.scope };
        while (!builder.stopped) {
            const token_start = lexer.pos;
            const token = (lexer.next() catch |err| {
                if (err == error.OutOfMemory) return err;
                builder.unknown();
                break;
            }) orelse break;
            if (token == .number and !vectorNumberTokenIsValid(content[token_start..lexer.pos], token.number)) {
                builder.unknown();
                break;
            }
            if (token != .operator) {
                if (count == operands.len) {
                    builder.limited(true);
                    break;
                }
                _ = pushOperand(&operands, &count, token);
                continue;
            }
            if (!builder.operator()) break;
            const op = token.operator;
            if (std.mem.eql(u8, op, "Do")) {
                if (count != 1 or operands[0] != .name) {
                    builder.unknown();
                } else self.collectVectorForm(operands[0].name, context, builder, collector.graphics) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    if (err == error.FormDepthLimitExceeded or err == error.FormInvocationLimitExceeded) builder.limited(true) else builder.unknown();
                };
            } else try collector.consume(op, operands[0..count]);
            count = 0;
            // No shape borrows operands. Bound temporary decoded strings to one
            // operator rather than retaining every text token on the page.
            _ = token_arena.reset(.retain_capacity);
        }
        if (count != 0 and !builder.stopped) builder.unknown();
        collector.endStream();
    }

    fn vectorNumberTokenIsValid(raw: []const u8, value: f64) bool {
        // The shared permissive lexer can replace an invalid numeric token
        // with zero. Validate its original bytes before using path geometry.
        if (!std.math.isFinite(value) or raw.len == 0) return false;
        var start = raw.len;
        while (start > 0 and raw[start - 1] != 0 and !std.ascii.isWhitespace(raw[start - 1])) start -= 1;
        const parsed = std.fmt.parseFloat(f64, raw[start..]) catch return false;
        return std.math.isFinite(parsed);
    }

    fn collectVectorForm(self: *Document, name: []const u8, context: *const ExtractionContext, builder: *vector_evidence.Builder, parent: vector_evidence.Graphics) anyerror!void {
        // Image Do is deliberately excluded from painted-path evidence.
        const parent_resources = context.resources orelse return error.MissingVectorResources;
        const xobjects = try resolveContextDict(context, parent_resources.get("XObject") orelse return error.MissingVectorXObjects);
        const object = xobjects.get(name) orelse return error.MissingFormXObject;
        const form = (try resolveForm(context, name)) orelse {
            const resolved = try resolveContextObject(context, object);
            if (resolved == .stream and std.mem.eql(u8, resolved.stream.dict.getName("Subtype") orelse "", "Image")) return;
            return error.UnsupportedVectorXObject;
        };
        const traversal = context.traversal orelse return error.MissingFormTraversal;
        const scope = try traversal.enter(.{ .object_num = form.reference.num, .generation = form.reference.gen });
        defer traversal.leave();
        var arena = std.heap.ArenaAllocator.init(context.scratch_allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const content = try decompress.decompressStream(scratch, form.stream.data, form.stream.dict.get("Filter"), form.stream.dict.get("DecodeParms"));
        var child = context.*;
        child.scratch_allocator = scratch;
        child.scope = scope;
        if (form.stream.dict.get("Resources")) |resources| child.resources = try resolveContextDict(context, resources);
        var graphics = parent;
        graphics.paint_state = try formGraphicsState(parent.paint_state, form.stream.dict);
        if (graphics.paint_state.clip_unknown and !parent.paint_state.clip_unknown) builder.unknown();
        try self.collectVectorEvidence(content, &child, builder, graphics);
    }

    pub fn getPageImagesFromContent(
        self: *Document,
        page_idx: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
    ) ![]ImageInfo {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        if (content.len == 0) return allocator.alloc(ImageInfo, 0);

        // Parse content stream for Do operators and track CTM
        var images: std.ArrayList(ImageInfo) = .empty;
        errdefer images.deinit(allocator);
        var traversal = form_scope.Traversal{ .page_index = @intCast(page_idx) };
        const context = self.contentContext(page_idx, scratch_allocator, &traversal);
        try self.collectPageImagesFromContent(page_idx, allocator, scratch_allocator, content, &context, @import("paint.zig").identity, &images);
        return images.toOwnedSlice(allocator);
    }

    fn collectPageImagesFromContent(self: *Document, page_idx: usize, allocator: std.mem.Allocator, scratch_allocator: std.mem.Allocator, content: []const u8, context: *const ExtractionContext, initial_ctm: [6]f64, images: *std.ArrayList(ImageInfo)) anyerror!void {
        var page = self.pages.items[page_idx];
        page.resources = context.resources;

        var lexer = interpreter.ContentLexer.init(scratch_allocator, content);
        var operands: [128]interpreter.Operand = undefined;
        var operand_count: usize = 0;

        const paint_mod = @import("paint.zig");
        var ctm = initial_ctm;
        var ctm_stack: std.ArrayList([6]f64) = .empty;
        defer ctm_stack.deinit(allocator);

        while (try lexer.next()) |token| {
            if (pushOperand(&operands, &operand_count, token)) continue;

            const op = token.operator;
            if (op.len > 0) {
                if (std.mem.eql(u8, op, "q")) {
                    try ctm_stack.append(allocator, ctm);
                } else if (std.mem.eql(u8, op, "Q")) {
                    if (ctm_stack.pop()) |saved| ctm = saved;
                } else if (std.mem.eql(u8, op, "cm") and operand_count >= 6) {
                    // Concatenate matrix
                    const new: [6]f64 = .{
                        operands[0].number, operands[1].number,
                        operands[2].number, operands[3].number,
                        operands[4].number, operands[5].number,
                    };
                    ctm = paint_mod.concat(ctm, new);
                } else if (std.mem.eql(u8, op, "Do") and operand_count >= 1 and operands[0] == .name) {
                    // Check if this XObject is an Image
                    if (self.resolveXObjectImage(page, operands[0].name)) |img_info| {
                        // Images paint a unit square; affine transforms can
                        // rotate, reflect or shear every corner independently.
                        const points = [_][2]f64{
                            transformPoint(ctm, .{ 0, 0 }),
                            transformPoint(ctm, .{ 1, 0 }),
                            transformPoint(ctm, .{ 0, 1 }),
                            transformPoint(ctm, .{ 1, 1 }),
                        };
                        var rect = [4]f64{ points[0][0], points[0][1], points[0][0], points[0][1] };
                        for (points[1..]) |point| {
                            rect[0] = @min(rect[0], point[0]);
                            rect[1] = @min(rect[1], point[1]);
                            rect[2] = @max(rect[2], point[0]);
                            rect[3] = @max(rect[3], point[1]);
                        }
                        if (context.initial.graphics.clip_bbox) |clip| {
                            rect[0] = @max(rect[0], clip.x0);
                            rect[1] = @max(rect[1], clip.y0);
                            rect[2] = @min(rect[2], clip.x1);
                            rect[3] = @min(rect[3], clip.y1);
                            if (rect[0] >= rect[2] or rect[1] >= rect[3]) {
                                operand_count = 0;
                                continue;
                            }
                        }
                        try images.append(allocator, .{
                            .rect = rect,
                            .width = img_info.width,
                            .height = img_info.height,
                        });
                    } else if (try resolveForm(context, operands[0].name)) |form| {
                        const traversal = context.traversal orelse return error.MissingFormTraversal;
                        const scope = try traversal.enter(.{ .object_num = form.reference.num, .generation = form.reference.gen });
                        defer traversal.leave();
                        var arena = std.heap.ArenaAllocator.init(scratch_allocator);
                        defer arena.deinit();
                        const scratch = arena.allocator();
                        const form_content = try decompress.decompressStream(scratch, form.stream.data, form.stream.dict.get("Filter"), form.stream.dict.get("DecodeParms"));
                        var child = context.*;
                        child.scratch_allocator = scratch;
                        child.scope = scope;
                        if (form.stream.dict.get("Resources")) |resource_object| child.resources = try resolveContextDict(context, resource_object);
                        var parent_state = context.initial.graphics;
                        parent_state.ctm = ctm;
                        child.initial.graphics = try formGraphicsState(parent_state, form.stream.dict);
                        try self.collectPageImagesFromContent(page_idx, allocator, scratch, form_content, &child, child.initial.graphics.ctm, images);
                    }
                }
            }

            operand_count = 0;
        }
    }

    fn multiplyMatrix(a: [6]f64, b: [6]f64) [6]f64 {
        return .{
            a[0] * b[0] + a[1] * b[2],
            a[0] * b[1] + a[1] * b[3],
            a[2] * b[0] + a[3] * b[2],
            a[2] * b[1] + a[3] * b[3],
            a[4] * b[0] + a[5] * b[2] + b[4],
            a[4] * b[1] + a[5] * b[3] + b[5],
        };
    }

    const XObjectImageInfo = struct { width: u32, height: u32 };

    fn resolveXObjectImage(self: *Document, page: Page, name: []const u8) ?XObjectImageInfo {
        const arena = self.parsing_arena.allocator();
        const resources = page.resources orelse return null;

        const xobjects_obj = resources.get("XObject") orelse return null;
        const xobjects = switch (xobjects_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch return null;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return null,
                };
            },
            else => return null,
        };

        const xobj_obj = xobjects.get(name) orelse return null;
        const xobj_stream = switch (xobj_obj) {
            .stream => |s| s,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch return null;
                break :blk switch (obj) {
                    .stream => |s| s,
                    else => return null,
                };
            },
            else => return null,
        };

        const subtype = xobj_stream.dict.getName("Subtype") orelse return null;
        if (!std.mem.eql(u8, subtype, "Image")) return null;

        const width: u32 = if (xobj_stream.dict.getInt("Width")) |w| @intCast(w) else return null;
        const height: u32 = if (xobj_stream.dict.getInt("Height")) |h| @intCast(h) else return null;

        return .{ .width = width, .height = height };
    }

    pub fn freeImages(allocator: std.mem.Allocator, images: []ImageInfo) void {
        allocator.free(images);
    }

    /// Detect stroked horizontal/vertical ruling lines on a page.
    /// Caller must free the returned slice.
    pub fn getPageRulingLines(self: *Document, page_idx: usize, allocator: std.mem.Allocator) ![]specialists.RulingLine {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const content = self.getPageContentForScratch(page_idx, scratch_allocator) catch return allocator.alloc(specialists.RulingLine, 0);
        return self.getPageRulingLinesFromContent(page_idx, allocator, scratch_allocator, content);
    }

    /// Detect stroked horizontal/vertical ruling lines from already-decoded content.
    pub fn getPageRulingLinesFromContent(
        self: *Document,
        page_idx: usize,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        content: []const u8,
    ) ![]specialists.RulingLine {
        if (page_idx >= self.pages.items.len) return error.PageNotFound;

        if (content.len == 0) return allocator.alloc(specialists.RulingLine, 0);

        var out: std.ArrayList(specialists.RulingLine) = .empty;
        errdefer out.deinit(allocator);
        var pending: std.ArrayList(specialists.RulingLine) = .empty;
        defer pending.deinit(allocator);

        var lexer = interpreter.ContentLexer.init(scratch_allocator, content);
        var operands: [128]interpreter.Operand = undefined;
        var operand_count: usize = 0;

        var ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 };
        var ctm_stack: [32][6]f64 = undefined;
        var ctm_stack_count: usize = 0;
        var stroke_width: f64 = 1;
        var current_point: ?[2]f64 = null;

        while (try lexer.next()) |token| {
            if (pushOperand(&operands, &operand_count, token)) continue;

            const op = token.operator;
            if (std.mem.eql(u8, op, "q")) {
                if (ctm_stack_count < ctm_stack.len) {
                    ctm_stack[ctm_stack_count] = ctm;
                    ctm_stack_count += 1;
                }
            } else if (std.mem.eql(u8, op, "Q")) {
                if (ctm_stack_count > 0) {
                    ctm_stack_count -= 1;
                    ctm = ctm_stack[ctm_stack_count];
                }
            } else if (std.mem.eql(u8, op, "cm") and operand_count >= 6) {
                const new: [6]f64 = .{
                    operands[0].number, operands[1].number,
                    operands[2].number, operands[3].number,
                    operands[4].number, operands[5].number,
                };
                ctm = multiplyMatrix(new, ctm);
            } else if (std.mem.eql(u8, op, "w") and operand_count >= 1 and operands[0] == .number) {
                stroke_width = operands[0].number;
            } else if (std.mem.eql(u8, op, "m") and operand_count >= 2) {
                current_point = transformPoint(ctm, .{ operands[0].asNumber(), operands[1].asNumber() });
            } else if (std.mem.eql(u8, op, "l") and operand_count >= 2) {
                const next_point = transformPoint(ctm, .{ operands[0].asNumber(), operands[1].asNumber() });
                if (current_point) |start| {
                    try appendAxisAlignedRuling(allocator, &pending, start, next_point, stroke_width);
                }
                current_point = next_point;
            } else if (std.mem.eql(u8, op, "re") and operand_count >= 4) {
                try appendRectRulings(allocator, &pending, ctm, .{
                    operands[0].asNumber(),
                    operands[1].asNumber(),
                    operands[2].asNumber(),
                    operands[3].asNumber(),
                }, stroke_width);
            } else if (isStrokeOperator(op)) {
                try out.appendSlice(allocator, pending.items);
                pending.clearRetainingCapacity();
                current_point = null;
            } else if (isPathDiscardOperator(op)) {
                pending.clearRetainingCapacity();
                current_point = null;
            }

            operand_count = 0;
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn freeRulingLines(allocator: std.mem.Allocator, lines: []specialists.RulingLine) void {
        allocator.free(lines);
    }

    fn transformPoint(matrix: [6]f64, point: [2]f64) [2]f64 {
        return .{
            point[0] * matrix[0] + point[1] * matrix[2] + matrix[4],
            point[0] * matrix[1] + point[1] * matrix[3] + matrix[5],
        };
    }

    fn appendRectRulings(
        allocator: std.mem.Allocator,
        out: *std.ArrayList(specialists.RulingLine),
        matrix: [6]f64,
        rect: [4]f64,
        stroke_width: f64,
    ) !void {
        const x = rect[0];
        const y = rect[1];
        const w = rect[2];
        const h = rect[3];
        const p0 = transformPoint(matrix, .{ x, y });
        const p1 = transformPoint(matrix, .{ x + w, y });
        const p2 = transformPoint(matrix, .{ x + w, y + h });
        const p3 = transformPoint(matrix, .{ x, y + h });
        try appendAxisAlignedRuling(allocator, out, p0, p1, stroke_width);
        try appendAxisAlignedRuling(allocator, out, p1, p2, stroke_width);
        try appendAxisAlignedRuling(allocator, out, p2, p3, stroke_width);
        try appendAxisAlignedRuling(allocator, out, p3, p0, stroke_width);
    }

    fn appendAxisAlignedRuling(
        allocator: std.mem.Allocator,
        out: *std.ArrayList(specialists.RulingLine),
        start: [2]f64,
        end: [2]f64,
        stroke_width: f64,
    ) !void {
        const dx = @abs(end[0] - start[0]);
        const dy = @abs(end[1] - start[1]);
        const epsilon = @max(0.5, stroke_width * 1.5);
        if (dx < epsilon and dy < epsilon) return;

        if (dy <= epsilon) {
            const half = @max(0.25, stroke_width / 2.0);
            try out.append(allocator, .{
                .bbox = .{
                    .x0 = @min(start[0], end[0]),
                    .y0 = start[1] - half,
                    .x1 = @max(start[0], end[0]),
                    .y1 = start[1] + half,
                },
                .orientation = .horizontal,
                .stroke_width = stroke_width,
            });
        } else if (dx <= epsilon) {
            const half = @max(0.25, stroke_width / 2.0);
            try out.append(allocator, .{
                .bbox = .{
                    .x0 = start[0] - half,
                    .y0 = @min(start[1], end[1]),
                    .x1 = start[0] + half,
                    .y1 = @max(start[1], end[1]),
                },
                .orientation = .vertical,
                .stroke_width = stroke_width,
            });
        }
    }

    fn isStrokeOperator(op: []const u8) bool {
        return std.mem.eql(u8, op, "S") or
            std.mem.eql(u8, op, "s") or
            std.mem.eql(u8, op, "B") or
            std.mem.eql(u8, op, "B*");
    }

    fn isPathDiscardOperator(op: []const u8) bool {
        return std.mem.eql(u8, op, "n") or
            std.mem.eql(u8, op, "f") or
            std.mem.eql(u8, op, "F") or
            std.mem.eql(u8, op, "f*");
    }

    // =========================================================================
    // Feature 7: Form Fields (/AcroForm)
    // =========================================================================

    pub const FieldType = enum { text, button, choice, signature, unknown };

    pub const FormField = struct {
        name: []const u8,
        value: ?[]const u8,
        field_type: FieldType,
        rect: ?[4]f64,
    };

    /// Extract form fields from the document's AcroForm.
    /// Caller must free the returned slice and each name/value string.
    pub fn getFormFields(self: *Document, allocator: std.mem.Allocator) ![]FormField {
        const arena = self.parsing_arena.allocator();

        // Get catalog
        const root_ref = switch (self.xref_table.trailer.get("Root") orelse return allocator.alloc(FormField, 0)) {
            .reference => |r| r,
            else => return allocator.alloc(FormField, 0),
        };
        const catalog = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, root_ref, &self.object_cache, self.securityHandler()) catch
            return allocator.alloc(FormField, 0);
        const catalog_dict = switch (catalog) {
            .dict => |d| d,
            else => return allocator.alloc(FormField, 0),
        };

        // Get /AcroForm dict
        const acroform_obj = catalog_dict.get("AcroForm") orelse return allocator.alloc(FormField, 0);
        const acroform = switch (acroform_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch
                    return allocator.alloc(FormField, 0);
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return allocator.alloc(FormField, 0),
                };
            },
            else => return allocator.alloc(FormField, 0),
        };

        // Get /Fields array
        const fields_obj = acroform.get("Fields") orelse return allocator.alloc(FormField, 0);
        const fields_arr = switch (fields_obj) {
            .array => |a| a,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch
                    return allocator.alloc(FormField, 0);
                break :blk switch (obj) {
                    .array => |a| a,
                    else => return allocator.alloc(FormField, 0),
                };
            },
            else => return allocator.alloc(FormField, 0),
        };

        var results: std.ArrayList(FormField) = .empty;
        errdefer {
            for (results.items) |f| {
                allocator.free(f.name);
                if (f.value) |v| allocator.free(v);
            }
            results.deinit(allocator);
        }

        // Walk fields (may have /Kids for hierarchical fields)
        for (fields_arr) |field_obj| {
            try self.collectFormFields(allocator, arena, field_obj, "", null, null, &results);
        }

        return results.toOwnedSlice(allocator);
    }

    fn collectFormFields(
        self: *Document,
        allocator: std.mem.Allocator,
        arena: std.mem.Allocator,
        field_obj: Object,
        parent_name: []const u8,
        inherited_type: ?FieldType,
        inherited_value: ?[]const u8,
        results: *std.ArrayList(FormField),
    ) !void {
        const field_dict = switch (field_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch return;
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return,
                };
            },
            else => return,
        };

        // Build full name: parent.child
        const partial_name = field_dict.getString("T") orelse "";
        const full_name = if (parent_name.len > 0 and partial_name.len > 0) blk: {
            const name = try allocator.alloc(u8, parent_name.len + 1 + partial_name.len);
            @memcpy(name[0..parent_name.len], parent_name);
            name[parent_name.len] = '.';
            @memcpy(name[parent_name.len + 1 ..], partial_name);
            break :blk name;
        } else if (partial_name.len > 0)
            try allocator.dupe(u8, partial_name)
        else
            try allocator.dupe(u8, parent_name);

        const effective_type = fieldTypeFromDict(field_dict) orelse inherited_type;
        const effective_value = fieldValueFromDict(field_dict) orelse inherited_value;

        // Check for /Kids (hierarchical field)
        if (field_dict.get("Kids")) |kids_obj| {
            const kids_arr = switch (kids_obj) {
                .array => |a| a,
                .reference => |r| blk: {
                    const obj = pagetree.resolveRefWithSecurity(arena, self.data, &self.xref_table, r, &self.object_cache, self.securityHandler()) catch {
                        allocator.free(full_name);
                        return;
                    };
                    break :blk switch (obj) {
                        .array => |a| a,
                        else => {
                            allocator.free(full_name);
                            return;
                        },
                    };
                },
                else => {
                    allocator.free(full_name);
                    return;
                },
            };

            for (kids_arr) |kid| {
                try self.collectFormFields(
                    allocator,
                    arena,
                    kid,
                    full_name,
                    effective_type,
                    effective_value,
                    results,
                );
            }
            allocator.free(full_name);
            return;
        }

        // Leaf field: extract type, value, rect
        const field_type = effective_type orelse .unknown;

        const value = if (effective_value) |v|
            try allocator.dupe(u8, v)
        else
            null;

        const rect = parseRect(field_dict);

        try results.append(allocator, .{
            .name = full_name,
            .value = value,
            .field_type = field_type,
            .rect = rect,
        });
    }

    fn fieldTypeFromDict(field_dict: anytype) ?FieldType {
        const ft_name = field_dict.getName("FT") orelse return null;
        if (std.mem.eql(u8, ft_name, "Tx")) return .text;
        if (std.mem.eql(u8, ft_name, "Btn")) return .button;
        if (std.mem.eql(u8, ft_name, "Ch")) return .choice;
        if (std.mem.eql(u8, ft_name, "Sig")) return .signature;
        return .unknown;
    }

    fn fieldValueFromDict(field_dict: anytype) ?[]const u8 {
        if (field_dict.getString("V")) |value| return value;
        if (field_dict.getName("V")) |value| return value;
        return null;
    }

    pub fn freeFormFields(allocator: std.mem.Allocator, fields: []FormField) void {
        for (fields) |f| {
            allocator.free(f.name);
            if (f.value) |v| allocator.free(v);
        }
        allocator.free(fields);
    }
};

/// Decode a PDF string that may be UTF-16BE (BOM-prefixed) into UTF-8.
/// If the string starts with \xFE\xFF it's UTF-16BE; otherwise it's
/// PDFDocEncoding, including its punctuation, accents and ligatures.
/// Caller owns the returned slice.
pub fn decodePdfString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Check for UTF-16BE BOM
    if (raw.len >= 2 and raw[0] == 0xFE and raw[1] == 0xFF) {
        const payload = raw[2..]; // skip BOM
        const n_units = payload.len / 2;

        // Decode UTF-16BE to UTF-8
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        try result.ensureTotalCapacity(allocator, n_units * 3); // worst case

        var i: usize = 0;
        while (i + 1 < payload.len) {
            const hi: u16 = @as(u16, payload[i]) << 8;
            const lo: u16 = payload[i + 1];
            const unit: u16 = hi | lo;
            i += 2;

            var codepoint: u21 = undefined;
            if (unit >= 0xD800 and unit <= 0xDBFF) {
                // High surrogate — need low surrogate
                if (i + 1 < payload.len) {
                    const hi2: u16 = @as(u16, payload[i]) << 8;
                    const lo2: u16 = payload[i + 1];
                    const unit2: u16 = hi2 | lo2;
                    i += 2;
                    if (unit2 >= 0xDC00 and unit2 <= 0xDFFF) {
                        codepoint = 0x10000 + (@as(u21, unit - 0xD800) << 10) + @as(u21, unit2 - 0xDC00);
                    } else {
                        codepoint = 0xFFFD; // replacement
                    }
                } else {
                    codepoint = 0xFFFD;
                }
            } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
                codepoint = 0xFFFD; // unpaired low surrogate
            } else {
                codepoint = unit;
            }

            // Encode as UTF-8
            if (codepoint < 0x80) {
                try result.append(allocator, @intCast(codepoint));
            } else if (codepoint < 0x800) {
                try result.append(allocator, @intCast(0xC0 | (codepoint >> 6)));
                try result.append(allocator, @intCast(0x80 | (codepoint & 0x3F)));
            } else if (codepoint < 0x10000) {
                try result.append(allocator, @intCast(0xE0 | (codepoint >> 12)));
                try result.append(allocator, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | (codepoint & 0x3F)));
            } else {
                try result.append(allocator, @intCast(0xF0 | (codepoint >> 18)));
                try result.append(allocator, @intCast(0x80 | ((codepoint >> 12) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | ((codepoint >> 6) & 0x3F)));
                try result.append(allocator, @intCast(0x80 | (codepoint & 0x3F)));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    // Preserve the byte fast path only where PDFDocEncoding is identity.
    var needs_encoding = false;
    for (raw) |byte| {
        if (encoding.pdf_doc_encoding[byte] != byte or byte >= 0x80 or byte == 0) {
            needs_encoding = true;
            break;
        }
    }
    if (!needs_encoding) return allocator.dupe(u8, raw);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (raw) |byte| {
        const mapped = encoding.pdf_doc_encoding[byte];
        // Zero is the table's undefined sentinel; an explicit NUL is retained.
        const codepoint: u21 = if (mapped == 0 and byte != 0) 0xfffd else mapped;
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        try result.appendSlice(allocator, encoded[0..length]);
    }

    return result.toOwnedSlice(allocator);
}

/// Context for text extraction (allows Form XObject recursion)
const ExtractionContext = struct {
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref_table: *const XRefTable,
    object_cache: *std.AutoHashMap(u32, Object),
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    page_num: usize,
    depth: u8, // Recursion depth for nested Form XObjects
    security: ?*const encryption.SecurityHandler,
    selection_metrics: ?*StructuredSelectionMetrics = null,
    resources: ?Object.Dict = null,
    traversal: ?*form_scope.Traversal = null,
    scope: ?form_scope.Scope = null,
    initial: FormTextState = .{},
};

const FormTextState = struct {
    graphics: @import("paint.zig").State = .{},
    font: ?*const encoding.FontEncoding = null,
    font_name: ?[]const u8 = null,
    font_size: f64 = 12,
    leading: f64 = 0,
    char_spacing: f64 = 0,
    word_spacing: f64 = 0,
    horizontal_scale: f64 = 100,
    rise: f64 = 0,
};

const TextSelection = enum {
    structured,
    table,
    full_context,
    legacy_fallback,
};

const StructuredSelectionMetrics = struct {
    form_xobjects_decoded: usize = 0,
    inventory_codepoints: usize = 0,
    candidate_codepoints: usize = 0,
    missing_codepoints: usize = 0,
    extra_codepoints: usize = 0,
    selected: TextSelection = .legacy_fallback,

    fn recordCandidate(self: *StructuredSelectionMetrics, comparison: TextContentComparison) void {
        self.candidate_codepoints = comparison.candidate_codepoints;
        self.missing_codepoints = comparison.missing_codepoints;
        self.extra_codepoints = comparison.extra_codepoints;
    }
};

const TextContentComparison = struct {
    inventory_codepoints: usize = 0,
    candidate_codepoints: usize = 0,
    missing_codepoints: usize = 0,
    extra_codepoints: usize = 0,

    fn equivalent(self: TextContentComparison) bool {
        return self.missing_codepoints == 0 and self.extra_codepoints == 0;
    }
};

/// Extraction mode: controls how operators are dispatched
const ExtractionMode = union(enum) {
    /// Basic text extraction to writer (supports Form XObjects via Do).
    /// ctx is null when no XObject resolution is needed (e.g. simple text-only paths).
    stream: struct {
        resources: ?Object.Dict,
        ctx: ?*const ExtractionContext,
    },
    /// Collect spans with bounding boxes
    bounds: *interpreter.SpanCollector,
    /// Track marked content IDs for structure tree reading order
    structured: *structtree.MarkedContentExtractor,
};

const ActualTextScope = struct {
    text: ?[]u8 = null,
    seen: bool = false,
};

const PoppedActualText = struct {
    text: []u8,
    seen: bool,
    suppressed_by_ancestor: bool,
};

/// Try to buffer a token as an operand. Returns true if consumed (not an operator).
fn pushOperand(operands: []interpreter.Operand, count: *usize, token: interpreter.ContentLexer.Token) bool {
    switch (token) {
        .operator => return false,
        .number => |n| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .number = n };
                count.* += 1;
            }
        },
        .string => |s| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .string = s };
                count.* += 1;
            }
        },
        .hex_string => |s| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .hex_string = s };
                count.* += 1;
            }
        },
        .name => |n| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .name = n };
                count.* += 1;
            }
        },
        .array => |a| {
            if (count.* < operands.len) {
                operands[count.*] = .{ .array = a };
                count.* += 1;
            }
        },
    }
    return true;
}

fn scanExtractionOperators(
    allocator: std.mem.Allocator,
    content: []const u8,
    report: *ExtractionDiagnostics,
) !void {
    var lexer = interpreter.ContentLexer.init(allocator, content);
    var operands: [128]interpreter.Operand = undefined;
    var operand_count: usize = 0;
    var in_text = false;

    while (try lexer.next()) |token| {
        if (pushOperand(&operands, &operand_count, token)) continue;

        const op = token.operator;
        report.operator_count += 1;
        if (std.mem.eql(u8, op, "BT")) {
            in_text = true;
            report.text_object_count += 1;
        } else if (std.mem.eql(u8, op, "ET")) {
            in_text = false;
        } else if (in_text and std.mem.eql(u8, op, "Tj") and operand_count >= 1) {
            report.text_show_operator_count += 1;
            report.text_operand_bytes += extractionOperandBytes(operands[0]);
        } else if (in_text and std.mem.eql(u8, op, "TJ") and operand_count >= 1) {
            report.text_show_operator_count += 1;
            report.text_operand_bytes += extractionOperandBytes(operands[0]);
        } else if (in_text and std.mem.eql(u8, op, "'") and operand_count >= 1) {
            report.text_show_operator_count += 1;
            report.text_operand_bytes += extractionOperandBytes(operands[0]);
        } else if (in_text and std.mem.eql(u8, op, "\"") and operand_count >= 3) {
            report.text_show_operator_count += 1;
            report.text_operand_bytes += extractionOperandBytes(operands[2]);
        }
        operand_count = 0;
    }
}

fn ensureFontReport(
    allocator: std.mem.Allocator,
    reports: *std.ArrayList(extraction_diagnostics.FontReport),
    resource_name: []const u8,
    font: *const encoding.FontEncoding,
) !*extraction_diagnostics.FontReport {
    for (reports.items) |*report| {
        if (font.font_object_num != null and report.font_object == font.font_object_num) return report;
        if (font.font_object_num == null and report.font_object == null and
            std.mem.eql(u8, report.resource_name, resource_name) and
            std.mem.eql(u8, report.base_font, font.base_font orelse ""))
        {
            return report;
        }
    }

    const owned_resource_name = try allocator.dupe(u8, resource_name);
    errdefer allocator.free(owned_resource_name);
    const embedded_font_type = if (font.embedded_font) |*embedded| embedded.name() else "none";
    try reports.append(allocator, .{
        .font_object = font.font_object_num,
        .resource_name = owned_resource_name,
        .subtype = font.subtype orelse "unknown",
        .base_font = font.base_font orelse "",
        .encoding_cmap_name = font.code_cmap.name orelse font.code_cmap.usecmap_name orelse "",
        .cid_registry = if (font.is_cid) font.cid_system_info.registry else "",
        .cid_ordering = if (font.is_cid) font.cid_system_info.ordering else "",
        .cid_supplement = if (font.is_cid) font.cid_system_info.supplement else 0,
        .to_unicode_present = font.to_unicode.explicit,
        .to_unicode_mapped_codes = toUnicodeMappedCodeCount(&font.to_unicode),
        .embedded_font_type = embedded_font_type,
        .cid_to_gid_map_type = if (font.is_cid) font.cid_to_gid.name() else "not_applicable",
        .type3_charproc_metrics = font.type3_charproc_metrics.count(),
        .type3_d1_bboxes = type3D1MetricCount(font),
    });
    return &reports.items[reports.items.len - 1];
}

fn type3D1MetricCount(font: *const encoding.FontEncoding) usize {
    var count: usize = 0;
    var metrics = font.type3_charproc_metrics.iterator();
    while (metrics.next()) |entry| {
        if (entry.value_ptr.operator == .d1) count += 1;
    }
    return count;
}

fn toUnicodeMappedCodeCount(map: *const encoding.CodeToUnicodeMap) usize {
    var count: usize = @as(usize, map.scalar_map.count()) + @as(usize, map.multi_map.count());
    for (map.ranges) |range| {
        const range_count: usize = @intCast(range.src_end - range.src_start + 1);
        count +|= range_count;
    }
    return count;
}

fn extractionOperandBytes(operand: interpreter.Operand) usize {
    return switch (operand) {
        .string => |bytes| bytes.len,
        .hex_string => |bytes| bytes.len,
        .array => |items| blk: {
            var total: usize = 0;
            for (items) |item| total += extractionOperandBytes(item);
            break :blk total;
        },
        else => 0,
    };
}

fn utf8CodepointCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

fn comparableCodepointCount(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (nextComparableCodepoint(text, &index)) |_| count += 1;
    return count;
}

fn compareTextContent(
    allocator: std.mem.Allocator,
    inventory: []const u8,
    candidate: []const u8,
) !TextContentComparison {
    var remaining = std.AutoHashMap(u21, usize).init(allocator);
    defer remaining.deinit();

    var comparison: TextContentComparison = .{};
    var index: usize = 0;
    while (nextComparableCodepoint(inventory, &index)) |codepoint| {
        comparison.inventory_codepoints += 1;
        const entry = try remaining.getOrPut(codepoint);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    index = 0;
    while (nextComparableCodepoint(candidate, &index)) |codepoint| {
        comparison.candidate_codepoints += 1;
        if (remaining.getPtr(codepoint)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                continue;
            }
        }
        comparison.extra_codepoints += 1;
    }

    var iterator = remaining.valueIterator();
    while (iterator.next()) |count| comparison.missing_codepoints += count.*;
    return comparison;
}

fn nextComparableCodepoint(text: []const u8, index: *usize) ?u21 {
    while (index.* < text.len) {
        const start = index.*;
        const sequence_len: usize = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
        if (start + sequence_len > text.len) {
            index.* += 1;
            const fallback: u21 = @intCast(text[start]);
            if (!isSelectionWhitespace(fallback)) return fallback;
            continue;
        }

        const codepoint = std.unicode.utf8Decode(text[start .. start + sequence_len]) catch blk: {
            index.* += 1;
            break :blk @as(u21, @intCast(text[start]));
        };
        if (index.* == start) index.* += sequence_len;
        if (!isSelectionWhitespace(codepoint)) return codepoint;
    }
    return null;
}

fn isSelectionWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000D,
        0x0020,
        0x0085,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        => true,
        else => false,
    };
}

test "structured selection compares Unicode content as a multiset" {
    const reordered = try compareTextContent(std.testing.allocator, "alpha βeta", "βeta\nalpha");
    try std.testing.expect(reordered.equivalent());
    try std.testing.expectEqual(@as(usize, 9), reordered.inventory_codepoints);

    const incomplete = try compareTextContent(std.testing.allocator, "main form", "main");
    try std.testing.expect(!incomplete.equivalent());
    try std.testing.expectEqual(@as(usize, 4), incomplete.missing_codepoints);
    try std.testing.expectEqual(@as(usize, 0), incomplete.extra_codepoints);
}

/// Look up a font encoding in the cache by page number and font name.
fn lookupFont(
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    key_buf: *[256]u8,
    page_num: usize,
    font_name: []const u8,
) ?*const encoding.FontEncoding {
    const key = std.fmt.bufPrint(key_buf, "{d}:{s}", .{ page_num, font_name }) catch return null;
    return font_cache.getPtr(key);
}

/// Extract text with full context (supports Form XObjects)
fn extractTextFromContentFull(
    content: []const u8,
    resources: ?Object.Dict,
    ctx: *const ExtractionContext,
    writer: anytype,
) !void {
    var traversal = form_scope.Traversal{ .page_index = @intCast(ctx.page_num) };
    var frame = ctx.*;
    frame.resources = resources;
    if (frame.traversal == null) frame.traversal = &traversal;
    if (frame.scope == null) frame.scope = form_scope.Scope.page(@intCast(ctx.page_num));
    try extractContentStreamContext(content, .{ .stream = .{
        .resources = resources,
        .ctx = &frame,
    } }, ctx.font_cache, ctx.page_num, ctx.scratch_allocator, writer, &frame);
}

/// Unified content stream extraction. All three extraction paths go through this.
fn extractContentStream(
    content: []const u8,
    mode: ExtractionMode,
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    page_num: usize,
    allocator: std.mem.Allocator,
    writer: anytype,
) !void {
    try extractContentStreamContext(content, mode, font_cache, page_num, allocator, writer, if (mode == .stream) mode.stream.ctx else null);
}

fn extractContentStreamContext(
    content: []const u8,
    mode: ExtractionMode,
    font_cache: *const std.StringHashMap(encoding.FontEncoding),
    page_num: usize,
    allocator: std.mem.Allocator,
    writer: anytype,
    context: ?*const ExtractionContext,
) anyerror!void {
    const initial = if (context) |ctx| ctx.initial else FormTextState{};
    var lexer = interpreter.ContentLexer.init(allocator, content);
    var operands: [128]interpreter.Operand = undefined;
    var operand_count: usize = 0;

    var current_font: ?*const encoding.FontEncoding = initial.font;
    var current_font_name: ?[]const u8 = initial.font_name;
    var prev_x: f64 = 0;
    var prev_y: f64 = 0;
    var current_x: f64 = 0;
    var current_y: f64 = 0;
    var line_start_x: f64 = 0;
    var line_start_y: f64 = 0;
    var font_size: f64 = initial.font_size;
    var text_leading: f64 = initial.leading;
    var char_spacing: f64 = initial.char_spacing;
    var word_spacing: f64 = initial.word_spacing;
    var horizontal_scale: f64 = initial.horizontal_scale;
    var text_rise: f64 = initial.rise;
    var text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 };
    var in_text = false;
    const paint_mod = @import("paint.zig");
    const inherited_actual_text = if (mode == .bounds) mode.bounds.current_actual_text else null;
    var paint_tracker: paint_mod.Tracker = .{ .state = initial.graphics };
    defer paint_tracker.deinit(allocator);
    const SavedTextState = struct {
        font: ?*const encoding.FontEncoding,
        font_name: ?[]const u8,
        font_size: f64,
        leading: f64,
        char_spacing: f64,
        word_spacing: f64,
        horizontal_scale: f64,
        rise: f64,
    };
    var saved_text_states: std.ArrayList(SavedTextState) = .empty;
    defer saved_text_states.deinit(allocator);
    if (mode == .bounds) {
        const collector = mode.bounds;
        collector.setGraphicsState(paint_tracker.state);
        if (context) |ctx| collector.setContentScope(ctx.scope);
        collector.setFont(initial.font_name, font_size, if (current_font) |font| font.has_to_unicode else null);
        collector.current_writing_mode = if (current_font) |font| font.wmode else 0;
        collector.current_font_is_type3 = if (current_font) |font| font.is_type3 else false;
        collector.current_font_space_width = if (current_font) |font| (if (!font.is_cid) font.widths.getWidth(' ') else 0) else 0;
        collector.setTextState(.{ .char_spacing = char_spacing, .word_spacing = word_spacing, .horizontal_scale = horizontal_scale, .text_rise = text_rise });
    }
    // Track the font size of the last shown text for newline threshold.
    // Superscripts/subscripts switch to a smaller Tf *before* their Tm, so
    // using raw font_size would make the threshold too small and produce
    // spurious newlines for every super/subscript.
    var last_text_font_size: f64 = 12;

    var key_buf: [256]u8 = undefined;

    // Text buffer for structured mode (MCID tracking).
    // Spans longer than MCID_TEXT_BUF_SIZE bytes are silently truncated.
    const MCID_TEXT_BUF_SIZE = 4096;
    var text_buf: [MCID_TEXT_BUF_SIZE]u8 = undefined;
    var text_pos: usize = 0;

    var actual_text_scopes: [32]ActualTextScope = undefined;
    @memset(&actual_text_scopes, .{});
    var actual_text_depth: usize = 0;
    defer cleanupActualTextScopes(allocator, actual_text_scopes[0..actual_text_depth]);

    while (try lexer.next()) |token| {
        if (pushOperand(&operands, &operand_count, token)) continue;

        // token is an operator
        const op = token.operator;
        var named_properties: [4]interpreter.Operand = undefined;
        if (std.mem.eql(u8, op, "BDC") and operand_count == 2 and operands[1] == .name) {
            const ctx = context orelse return error.MissingMarkedContentResources;
            const resources = ctx.resources orelse return error.MissingMarkedContentResources;
            const properties = try resolveContextDict(ctx, resources.get("Properties") orelse return error.MissingMarkedContentProperty);
            const property = try resolveContextDict(ctx, properties.get(operands[1].name) orelse return error.MissingMarkedContentProperty);
            var count: usize = 0;
            if (property.get("ActualText")) |value| {
                named_properties[count] = .{ .name = "ActualText" };
                named_properties[count + 1] = switch (try resolveContextObject(ctx, value)) {
                    .string => |text| .{ .string = text },
                    .hex_string => |text| .{ .hex_string = text },
                    else => return error.InvalidMarkedContentProperty,
                };
                count += 2;
            }
            if (property.get("MCID")) |value| {
                const mcid = switch (try resolveContextObject(ctx, value)) {
                    .integer => |number| number,
                    else => return error.InvalidMarkedContentProperty,
                };
                if (mcid < 0 or mcid > std.math.maxInt(i32)) return error.InvalidMarkedContentProperty;
                named_properties[count] = .{ .name = "MCID" };
                named_properties[count + 1] = .{ .number = @floatFromInt(mcid) };
                count += 2;
            }
            operands[1] = .{ .array = named_properties[0..count] };
        }
        const glyph_count_before = if (mode == .bounds) mode.bounds.glyphs.items.len else 0;
        if (mode != .bounds) {
            if (std.mem.eql(u8, op, "q")) {
                try paint_tracker.save(allocator);
                try saved_text_states.append(allocator, .{
                    .font = current_font,
                    .font_name = current_font_name,
                    .font_size = font_size,
                    .leading = text_leading,
                    .char_spacing = char_spacing,
                    .word_spacing = word_spacing,
                    .horizontal_scale = horizontal_scale,
                    .rise = text_rise,
                });
            } else if (std.mem.eql(u8, op, "Q")) {
                paint_tracker.restore();
                if (saved_text_states.pop()) |saved| {
                    current_font = saved.font;
                    current_font_name = saved.font_name;
                    font_size = saved.font_size;
                    text_leading = saved.leading;
                    char_spacing = saved.char_spacing;
                    word_spacing = saved.word_spacing;
                    horizontal_scale = saved.horizontal_scale;
                    text_rise = saved.rise;
                }
            } else if (std.mem.eql(u8, op, "cm") and operand_count >= 6) {
                var matrix: [6]f64 = undefined;
                for (operands[0..6], &matrix) |operand, *value| {
                    value.* = operand.asNumber();
                    if (operand != .number or !std.math.isFinite(value.*)) return error.InvalidFormMatrix;
                }
                paint_tracker.state.ctm = paint_mod.concat(paint_tracker.state.ctm, matrix);
            }
        }
        if (mode == .bounds) {
            const collector = mode.bounds;
            if (std.mem.eql(u8, op, "q")) {
                try collector.flush();
                try paint_tracker.save(allocator);
                try saved_text_states.append(allocator, .{
                    .font = current_font,
                    .font_name = collector.current_font_name,
                    .font_size = font_size,
                    .leading = text_leading,
                    .char_spacing = char_spacing,
                    .word_spacing = word_spacing,
                    .horizontal_scale = horizontal_scale,
                    .rise = text_rise,
                });
            } else if (std.mem.eql(u8, op, "Q")) {
                try collector.flush();
                paint_tracker.restore();
                if (saved_text_states.pop()) |saved| {
                    current_font = saved.font;
                    current_font_name = saved.font_name;
                    font_size = saved.font_size;
                    text_leading = saved.leading;
                    char_spacing = saved.char_spacing;
                    word_spacing = saved.word_spacing;
                    horizontal_scale = saved.horizontal_scale;
                    text_rise = saved.rise;
                    collector.setFont(saved.font_name, font_size, if (current_font) |font| font.has_to_unicode else null);
                    collector.current_writing_mode = if (current_font) |font| font.wmode else 0;
                    collector.current_font_is_type3 = if (current_font) |font| font.is_type3 else false;
                    collector.current_font_space_width = if (current_font) |font| (if (!font.is_cid) font.widths.getWidth(' ') else 0) else 0;
                    collector.setTextState(.{ .char_spacing = char_spacing, .word_spacing = word_spacing, .horizontal_scale = horizontal_scale, .text_rise = text_rise });
                }
            } else if (std.mem.eql(u8, op, "cm") and operand_count >= 6) {
                try collector.flush();
                var valid = true;
                for (operands[0..6]) |operand| {
                    if (operand != .number or !std.math.isFinite(operand.asNumber())) valid = false;
                }
                const next_ctm = paint_mod.concat(paint_tracker.state.ctm, .{
                    operands[0].asNumber(), operands[1].asNumber(), operands[2].asNumber(),
                    operands[3].asNumber(), operands[4].asNumber(), operands[5].asNumber(),
                });
                for (next_ctm) |value| {
                    if (!std.math.isFinite(value)) valid = false;
                }
                if (valid) paint_tracker.state.ctm = next_ctm else paint_tracker.state.geometry_known = false;
            } else if (std.mem.eql(u8, op, "cm")) {
                try collector.flush();
                paint_tracker.state.geometry_known = false;
            } else if (std.mem.eql(u8, op, "Tr") and operand_count >= 1) {
                try collector.flush();
                const value = operands[0].asNumber();
                paint_tracker.state.rendering_mode = if (operands[0] == .number and std.math.isFinite(value) and value >= 0 and value <= 7 and @floor(value) == value) @intFromFloat(value) else null;
            } else if (std.mem.eql(u8, op, "Tr")) {
                try collector.flush();
                paint_tracker.state.rendering_mode = null;
            } else if (std.mem.eql(u8, op, "re") and operand_count >= 4) {
                var valid = true;
                for (operands[0..4]) |operand| {
                    if (operand != .number or !std.math.isFinite(operand.asNumber())) valid = false;
                }
                if (valid) paint_tracker.rectangle(operands[0].asNumber(), operands[1].asNumber(), operands[2].asNumber(), operands[3].asNumber()) else paint_tracker.path_unknown = true;
            } else if (std.mem.eql(u8, op, "re")) {
                paint_tracker.path_unknown = true;
            } else if (std.mem.eql(u8, op, "W") or std.mem.eql(u8, op, "W*")) {
                paint_tracker.pending_clip = true;
            } else if (std.mem.eql(u8, op, "m") or std.mem.eql(u8, op, "l") or std.mem.eql(u8, op, "c") or std.mem.eql(u8, op, "v") or std.mem.eql(u8, op, "y")) {
                paint_tracker.path_unknown = true;
                paint_tracker.path_rect = null;
            } else if (std.mem.eql(u8, op, "n") or std.mem.eql(u8, op, "S") or std.mem.eql(u8, op, "s") or std.mem.eql(u8, op, "f") or std.mem.eql(u8, op, "F") or std.mem.eql(u8, op, "f*") or std.mem.eql(u8, op, "B") or std.mem.eql(u8, op, "B*") or std.mem.eql(u8, op, "b") or std.mem.eql(u8, op, "b*")) {
                if (paint_tracker.pending_clip) try collector.flush();
                paint_tracker.endPath();
            } else if (std.mem.eql(u8, op, "ET")) {
                try collector.flush();
                paint_tracker.endText();
            }
            collector.setGraphicsState(paint_tracker.state);
        }
        if (op.len > 0) switch (op[0]) {
            'B' => switch (mode) {
                .stream => {
                    if (op.len == 2 and op[1] == 'T') {
                        in_text = true;
                        prev_x = 0;
                        prev_y = 0;
                        current_x = 0;
                        current_y = 0;
                        line_start_x = 0;
                        line_start_y = 0;
                        text_matrix = .{ 1, 0, 0, 1, 0, 0 };
                    } else if (std.mem.eql(u8, op, "BDC")) {
                        try pushActualTextScope(allocator, &actual_text_scopes, &actual_text_depth, operands[0..operand_count], if (operand_count >= 2) 1 else 0);
                    } else if (std.mem.eql(u8, op, "BMC")) {
                        try pushEmptyActualTextScope(&actual_text_scopes, &actual_text_depth);
                    }
                },
                .bounds => |collector| {
                    if (op.len == 2 and op[1] == 'T') {
                        in_text = true;
                        current_x = 0;
                        current_y = 0;
                        line_start_x = 0;
                        line_start_y = 0;
                        text_matrix = .{ 1, 0, 0, 1, 0, 0 };
                        collector.setPosition(current_x, current_y);
                        collector.setTextMatrix(text_matrix);
                    } else if (std.mem.eql(u8, op, "BDC")) {
                        try pushActualTextScope(allocator, &actual_text_scopes, &actual_text_depth, operands[0..operand_count], if (operand_count >= 2) 1 else 0);
                        try collector.flush();
                        collector.setMcid(extractMcidFromOperands(operands[0..operand_count], if (operand_count >= 2) 1 else 0));
                        try collector.setActualText(effectiveActualText(actual_text_scopes[0..actual_text_depth], inherited_actual_text));
                    } else if (std.mem.eql(u8, op, "BMC")) {
                        try pushEmptyActualTextScope(&actual_text_scopes, &actual_text_depth);
                        try collector.flush();
                        try collector.setActualText(effectiveActualText(actual_text_scopes[0..actual_text_depth], inherited_actual_text));
                        collector.setMcid(null);
                    }
                },
                .structured => |extractor| {
                    if (op.len == 2 and op[1] == 'T') {
                        in_text = true;
                    } else if (std.mem.eql(u8, op, "BDC")) {
                        try pushActualTextScope(allocator, &actual_text_scopes, &actual_text_depth, operands[0..operand_count], if (operand_count >= 2) 1 else 0);
                        if (operand_count >= 2) {
                            const tag = operands[0].asName() orelse "Unknown";
                            const mcid = extractMcidFromOperands(operands[0..operand_count], 1);
                            try extractor.beginMarkedContent(tag, mcid);
                        }
                    } else if (std.mem.eql(u8, op, "BMC")) {
                        try pushEmptyActualTextScope(&actual_text_scopes, &actual_text_depth);
                        if (operand_count >= 1) {
                            const tag = operands[0].asName() orelse "Unknown";
                            try extractor.beginMarkedContent(tag, null);
                        }
                    }
                },
            },
            'E' => switch (mode) {
                .stream => {
                    if (op.len == 2 and op[1] == 'T') {
                        in_text = false;
                    } else if (std.mem.eql(u8, op, "EMC")) {
                        if (popActualTextScope(allocator, &actual_text_scopes, &actual_text_depth)) |actual| {
                            defer allocator.free(actual.text);
                            if (actual.seen and !actual.suppressed_by_ancestor) try writer.writeAll(actual.text);
                        }
                    }
                },
                .bounds => |collector| {
                    if (op.len == 2 and op[1] == 'T') {
                        try collector.flush();
                        in_text = false;
                    } else if (std.mem.eql(u8, op, "EMC")) {
                        try collector.flush();
                        if (popActualTextScope(allocator, &actual_text_scopes, &actual_text_depth)) |actual| {
                            allocator.free(actual.text);
                        }
                        try collector.setActualText(effectiveActualText(actual_text_scopes[0..actual_text_depth], inherited_actual_text));
                        collector.setMcid(null);
                    }
                },
                .structured => |extractor| {
                    if (op.len == 2 and op[1] == 'T') {
                        in_text = false;
                    } else if (std.mem.eql(u8, op, "EMC")) {
                        if (popActualTextScope(allocator, &actual_text_scopes, &actual_text_depth)) |actual| {
                            defer allocator.free(actual.text);
                            if (actual.seen and !actual.suppressed_by_ancestor) try extractor.addText(actual.text);
                        }
                        extractor.endMarkedContent();
                    }
                },
            },
            'D' => if (std.mem.eql(u8, op, "Do") and operand_count >= 1 and operands[0] == .name) {
                const replaced = if (mode == .bounds) false else markActualTextSeen(actual_text_scopes[0..actual_text_depth]);
                if (!replaced) {
                    const state = FormTextState{
                        .graphics = paint_tracker.state,
                        .font = current_font,
                        .font_name = current_font_name,
                        .font_size = font_size,
                        .leading = text_leading,
                        .char_spacing = char_spacing,
                        .word_spacing = word_spacing,
                        .horizontal_scale = horizontal_scale,
                        .rise = text_rise,
                    };
                    if (mode == .bounds) {
                        const collector = mode.bounds;
                        try collector.flush();
                        const saved_scope = collector.current_scope;
                        const saved_mcid = collector.current_mcid;
                        const saved_matrix = collector.current_text_matrix;
                        const saved_x = collector.current_x;
                        const saved_y = collector.current_y;
                        defer {
                            collector.setContentScope(saved_scope);
                            collector.setMcid(saved_mcid);
                            collector.setGraphicsState(paint_tracker.state);
                            collector.setFont(current_font_name, font_size, if (current_font) |font| font.has_to_unicode else null);
                            collector.current_writing_mode = if (current_font) |font| font.wmode else 0;
                            collector.current_font_is_type3 = if (current_font) |font| font.is_type3 else false;
                            collector.current_font_space_width = if (current_font) |font| (if (!font.is_cid) font.widths.getWidth(' ') else 0) else 0;
                            collector.setTextState(.{ .char_spacing = char_spacing, .word_spacing = word_spacing, .horizontal_scale = horizontal_scale, .text_rise = text_rise });
                            collector.setTextMatrix(saved_matrix);
                            collector.setPosition(saved_x, saved_y);
                        }
                        try handleFormOperator(operands[0].name, context, mode, state, writer);
                        try collector.flush();
                    } else try handleFormOperator(operands[0].name, context, mode, state, writer);
                }
            },
            'T' => if (op.len == 2) switch (op[1]) {
                'c' => if (operand_count >= 1) {
                    char_spacing = operands[0].asNumber();
                    if (mode == .bounds) mode.bounds.setTextState(.{
                        .char_spacing = char_spacing,
                        .word_spacing = word_spacing,
                        .horizontal_scale = horizontal_scale,
                        .text_rise = text_rise,
                    });
                },
                'w' => if (operand_count >= 1) {
                    word_spacing = operands[0].asNumber();
                    if (mode == .bounds) mode.bounds.setTextState(.{
                        .char_spacing = char_spacing,
                        .word_spacing = word_spacing,
                        .horizontal_scale = horizontal_scale,
                        .text_rise = text_rise,
                    });
                },
                'z' => if (operand_count >= 1) {
                    horizontal_scale = operands[0].asNumber();
                    if (mode == .bounds) mode.bounds.setTextState(.{
                        .char_spacing = char_spacing,
                        .word_spacing = word_spacing,
                        .horizontal_scale = horizontal_scale,
                        .text_rise = text_rise,
                    });
                },
                's' => if (operand_count >= 1) {
                    text_rise = operands[0].asNumber();
                    if (mode == .bounds) mode.bounds.setTextState(.{
                        .char_spacing = char_spacing,
                        .word_spacing = word_spacing,
                        .horizontal_scale = horizontal_scale,
                        .text_rise = text_rise,
                    });
                },
                'f' => if (operand_count >= 2) {
                    if (mode == .bounds) try mode.bounds.flush();
                    const font_name = if (operands[0] == .name) operands[0].name else null;
                    current_font_name = font_name;
                    if (operands[0] == .name) {
                        current_font = lookupFont(font_cache, &key_buf, page_num, operands[0].name);
                    }
                    font_size = operands[1].asNumber();
                    if (mode == .bounds) {
                        const has_to_unicode = if (current_font) |font| font.has_to_unicode else null;
                        mode.bounds.setFont(font_name, font_size, has_to_unicode);
                        mode.bounds.current_writing_mode = if (current_font) |font| font.wmode else 0;
                        mode.bounds.current_font_is_type3 = if (current_font) |font| font.is_type3 else false;
                        mode.bounds.current_font_space_width = if (current_font) |font| (if (!font.is_cid) font.widths.getWidth(' ') else 0) else 0;
                    }
                },
                'L' => if (in_text and operand_count >= 1) {
                    text_leading = operands[0].asNumber();
                },
                'd', 'D' => if (operand_count >= 2) {
                    if (!in_text) {
                        operand_count = 0;
                        continue;
                    }
                    const tx = operands[0].asNumber();
                    const ty = operands[1].asNumber();
                    if (op[1] == 'D') text_leading = -ty;
                    switch (mode) {
                        .stream => {
                            const wmode = if (current_font) |f| f.wmode else 0;
                            const displacement = if (wmode == 1) tx else ty;
                            // Use max(font_size, last_text_font_size) so that a small
                            // superscript font doesn't shrink the line-break threshold
                            // below the displacement used for super/subscript positioning.
                            const ref_size = @max(font_size, last_text_font_size);
                            if (@abs(displacement) > ref_size * 0.7 and prev_y != 0 and currentActualText(actual_text_scopes[0..actual_text_depth]) == null) {
                                try writer.writeByte('\n');
                            }
                            current_x = line_start_x + text_matrix[0] * tx + text_matrix[2] * ty;
                            current_y = line_start_y + text_matrix[1] * tx + text_matrix[3] * ty;
                            line_start_x = current_x;
                            line_start_y = current_y;
                            prev_y = current_y;
                            text_matrix[4] = current_x;
                            text_matrix[5] = current_y;
                        },
                        .bounds => |collector| {
                            current_x = line_start_x + text_matrix[0] * tx + text_matrix[2] * ty;
                            current_y = line_start_y + text_matrix[1] * tx + text_matrix[3] * ty;
                            line_start_x = current_x;
                            line_start_y = current_y;
                            text_matrix[4] = current_x;
                            text_matrix[5] = current_y;
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                            collector.setTextMatrix(text_matrix);
                        },
                        .structured => {},
                    }
                },
                'm' => if (operand_count >= 6) {
                    if (!in_text) {
                        operand_count = 0;
                        continue;
                    }
                    const tx = operands[4].asNumber();
                    const ty = operands[5].asNumber();
                    switch (mode) {
                        .stream => {
                            const wmode = if (current_font) |f| f.wmode else 0;
                            const new_pos = if (wmode == 1) tx else ty;
                            const prev_pos = if (wmode == 1) prev_x else prev_y;
                            const ref_size = @max(font_size, last_text_font_size);
                            if (@abs(new_pos - prev_pos) > ref_size * 0.7 and prev_pos != 0 and currentActualText(actual_text_scopes[0..actual_text_depth]) == null) {
                                try writer.writeByte('\n');
                            }
                            current_x = tx;
                            current_y = ty;
                            line_start_x = tx;
                            line_start_y = ty;
                            prev_x = tx;
                            prev_y = ty;
                            text_matrix = .{
                                operands[0].asNumber(),
                                operands[1].asNumber(),
                                operands[2].asNumber(),
                                operands[3].asNumber(),
                                tx,
                                ty,
                            };
                        },
                        .bounds => |collector| {
                            current_x = tx;
                            current_y = ty;
                            line_start_x = tx;
                            line_start_y = ty;
                            text_matrix = .{
                                operands[0].asNumber(),
                                operands[1].asNumber(),
                                operands[2].asNumber(),
                                operands[3].asNumber(),
                                tx,
                                ty,
                            };
                            try collector.flush();
                            collector.setPosition(current_x, current_y);
                            collector.setTextMatrix(text_matrix);
                        },
                        .structured => {},
                    }
                },
                '*' => switch (mode) {
                    .stream => if (in_text and currentActualText(actual_text_scopes[0..actual_text_depth]) == null) try writer.writeByte('\n'),
                    .bounds => |collector| if (in_text) {
                        try collector.flush();
                        const leading = if (text_leading != 0) text_leading else font_size;
                        current_x = line_start_x - text_matrix[2] * leading;
                        current_y = line_start_y - text_matrix[3] * leading;
                        line_start_x = current_x;
                        line_start_y = current_y;
                        text_matrix[4] = current_x;
                        text_matrix[5] = current_y;
                        collector.setPosition(current_x, current_y);
                        collector.setTextMatrix(text_matrix);
                    },
                    .structured => {},
                },
                'j' => if (operand_count >= 1) {
                    if (!in_text) {
                        operand_count = 0;
                        continue;
                    }
                    switch (mode) {
                        .stream => {
                            if (markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                                // ActualText replaces the glyph text when the marked-content scope closes.
                            } else {
                                try writeTextWithFont(operands[0], current_font, writer);
                            }
                            last_text_font_size = font_size;
                        },
                        .bounds => |collector| try writeTextToCollector(operands[0], current_font, collector),
                        .structured => |extractor| {
                            if (!markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                                text_pos = 0;
                                writeTextToBuffer(operands[0], current_font, &text_buf, &text_pos);
                                if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                            }
                        },
                    }
                },
                'J' => if (operand_count >= 1) {
                    if (!in_text) {
                        operand_count = 0;
                        continue;
                    }
                    switch (mode) {
                        .stream => {
                            if (markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                                // ActualText replaces the TJ glyph text at EMC.
                            } else {
                                try writeTJArrayWithFont(operands[0], current_font, writer);
                            }
                            last_text_font_size = font_size;
                        },
                        .bounds => |collector| try writeTJArrayToCollector(operands[0], current_font, collector),
                        .structured => |extractor| {
                            if (!markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                                text_pos = 0;
                                writeTJArrayToBuffer(operands[0], current_font, &text_buf, &text_pos);
                                if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                            }
                        },
                    }
                },
                else => {},
            },
            '\'' => if (operand_count >= 1) {
                if (!in_text) {
                    operand_count = 0;
                    continue;
                }
                switch (mode) {
                    .stream => {
                        if (currentActualText(actual_text_scopes[0..actual_text_depth]) == null) try writer.writeByte('\n');
                        if (markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                            // ActualText replaces this glyph run at EMC.
                        } else {
                            try writeTextWithFont(operands[0], current_font, writer);
                        }
                        last_text_font_size = font_size;
                    },
                    .bounds => |collector| {
                        try collector.flush();
                        const leading = if (text_leading != 0) text_leading else font_size;
                        current_x = line_start_x - text_matrix[2] * leading;
                        current_y = line_start_y - text_matrix[3] * leading;
                        line_start_x = current_x;
                        line_start_y = current_y;
                        text_matrix[4] = current_x;
                        text_matrix[5] = current_y;
                        collector.setPosition(current_x, current_y);
                        collector.setTextMatrix(text_matrix);
                        try writeTextToCollector(operands[0], current_font, collector);
                    },
                    .structured => |extractor| {
                        if (!markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                            text_pos = 0;
                            writeTextToBuffer(operands[0], current_font, &text_buf, &text_pos);
                            if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                        }
                    },
                }
            },
            '"' => if (operand_count >= 3) {
                if (!in_text) {
                    operand_count = 0;
                    continue;
                }
                word_spacing = operands[0].asNumber();
                char_spacing = operands[1].asNumber();
                switch (mode) {
                    .stream => {
                        if (currentActualText(actual_text_scopes[0..actual_text_depth]) == null) try writer.writeByte('\n');
                        if (markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                            // ActualText replaces this glyph run at EMC.
                        } else {
                            try writeTextWithFont(operands[2], current_font, writer);
                        }
                        last_text_font_size = font_size;
                    },
                    .bounds => |collector| {
                        try collector.flush();
                        collector.setTextState(.{ .char_spacing = char_spacing, .word_spacing = word_spacing, .horizontal_scale = horizontal_scale, .text_rise = text_rise });
                        const leading = if (text_leading != 0) text_leading else font_size;
                        current_x = line_start_x - text_matrix[2] * leading;
                        current_y = line_start_y - text_matrix[3] * leading;
                        line_start_x = current_x;
                        line_start_y = current_y;
                        text_matrix[4] = current_x;
                        text_matrix[5] = current_y;
                        collector.setPosition(current_x, current_y);
                        collector.setTextMatrix(text_matrix);
                        try writeTextToCollector(operands[2], current_font, collector);
                    },
                    .structured => |extractor| {
                        if (!markActualTextSeen(actual_text_scopes[0..actual_text_depth])) {
                            text_pos = 0;
                            writeTextToBuffer(operands[2], current_font, &text_buf, &text_pos);
                            if (text_pos > 0) try extractor.addText(text_buf[0..text_pos]);
                        }
                    },
                }
            },
            else => {},
        };

        if (mode == .bounds and mode.bounds.glyphs.items.len > glyph_count_before and !mode.bounds.current_font_is_type3) paint_tracker.shownText();
        operand_count = 0;
    }

    if (actual_text_depth > 0) {
        switch (mode) {
            .bounds => |collector| {
                try collector.flush();
                try collector.setActualText(inherited_actual_text);
            },
            else => {},
        }
    }
}

fn pushEmptyActualTextScope(scopes: *[32]ActualTextScope, depth: *usize) !void {
    if (depth.* >= scopes.len) return error.NestingTooDeep;
    scopes[depth.*] = .{};
    depth.* += 1;
}

fn pushActualTextScope(
    allocator: std.mem.Allocator,
    scopes: *[32]ActualTextScope,
    depth: *usize,
    operands: []const interpreter.Operand,
    property_start: usize,
) !void {
    if (depth.* >= scopes.len) return error.NestingTooDeep;
    var scope: ActualTextScope = .{};
    if (try extractActualTextFromOperands(allocator, operands, property_start)) |text| {
        scope.text = text;
    }
    scopes[depth.*] = scope;
    depth.* += 1;
}

fn popActualTextScope(allocator: std.mem.Allocator, scopes: *[32]ActualTextScope, depth: *usize) ?PoppedActualText {
    if (depth.* == 0) return null;
    depth.* -= 1;
    const scope = scopes[depth.*];
    scopes[depth.*] = .{};
    if (scope.text) |text| {
        return .{ .text = text, .seen = scope.seen, .suppressed_by_ancestor = currentActualText(scopes[0..depth.*]) != null };
    }
    _ = allocator;
    return null;
}

fn cleanupActualTextScopes(allocator: std.mem.Allocator, scopes: []ActualTextScope) void {
    for (scopes) |*scope| {
        if (scope.text) |text| {
            allocator.free(text);
            scope.text = null;
        }
    }
}

fn currentActualText(scopes: []const ActualTextScope) ?[]const u8 {
    // Deterministic extraction policy: an enclosing replacement owns the
    // complete lexical scope; descendants cannot emit competing replacements.
    for (scopes) |scope| if (scope.text) |text| return text;
    return null;
}

fn effectiveActualText(scopes: []const ActualTextScope, inherited: ?[]const u8) ?[]const u8 {
    return inherited orelse currentActualText(scopes);
}

fn markActualTextSeen(scopes: []ActualTextScope) bool {
    var found = false;
    for (scopes) |*scope| {
        if (scope.text != null) {
            scope.seen = true;
            found = true;
        }
    }
    return found;
}

fn extractActualTextFromOperands(
    allocator: std.mem.Allocator,
    operands: []const interpreter.Operand,
    property_start: usize,
) !?[]u8 {
    if (property_start >= operands.len) return null;
    if (try extractActualTextFromOperand(allocator, operands[property_start])) |text| return text;

    var i = property_start;
    while (i + 1 < operands.len) : (i += 1) {
        if (operands[i] == .name and std.mem.eql(u8, operands[i].name, "ActualText")) {
            return decodeActualTextOperand(allocator, operands[i + 1]);
        }
    }
    return null;
}

fn extractActualTextFromOperand(allocator: std.mem.Allocator, operand: interpreter.Operand) !?[]u8 {
    return switch (operand) {
        .array => |arr| blk: {
            var i: usize = 0;
            while (i + 1 < arr.len) : (i += 1) {
                if (arr[i] == .name and std.mem.eql(u8, arr[i].name, "ActualText")) {
                    break :blk try decodeActualTextOperand(allocator, arr[i + 1]);
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn decodeActualTextOperand(allocator: std.mem.Allocator, operand: interpreter.Operand) !?[]u8 {
    return switch (operand) {
        .string => |s| try decodePdfString(allocator, s),
        .hex_string => |s| try decodePdfString(allocator, s),
        else => null,
    };
}

fn resolveContextObject(ctx: *const ExtractionContext, object: Object) !Object {
    return switch (object) {
        .reference => |reference| try pagetree.resolveRefWithSecurity(ctx.parse_allocator, ctx.data, ctx.xref_table, reference, @constCast(ctx.object_cache), ctx.security),
        else => object,
    };
}

fn resolveContextDict(ctx: *const ExtractionContext, object: Object) !Object.Dict {
    return switch (try resolveContextObject(ctx, object)) {
        .dict => |dict| dict,
        else => error.InvalidFormResources,
    };
}

const ResolvedForm = struct { reference: ObjRef, stream: Object.Stream };

fn resolveForm(ctx: *const ExtractionContext, name: []const u8) !?ResolvedForm {
    const resources = ctx.resources orelse return null;
    const xobjects = try resolveContextDict(ctx, resources.get("XObject") orelse return null);
    const object = xobjects.get(name) orelse return error.MissingFormXObject;
    const resolved = try resolveContextObject(ctx, object);
    const resolved_stream = switch (resolved) {
        .stream => |value| value,
        else => return error.InvalidFormXObject,
    };
    if (!std.mem.eql(u8, resolved_stream.dict.getName("Subtype") orelse "", "Form")) return null;
    const reference = switch (object) {
        .reference => |reference| reference,
        else => return error.InvalidFormReference,
    };
    return .{ .reference = reference, .stream = resolved_stream };
}

fn formMatrix(dict: Object.Dict) ![6]f64 {
    const object = dict.get("Matrix") orelse return @import("paint.zig").identity;
    const array = switch (object) {
        .array => |array| array,
        else => return error.InvalidFormMatrix,
    };
    if (array.len != 6) return error.InvalidFormMatrix;
    var matrix: [6]f64 = undefined;
    for (array, &matrix) |value, *component| {
        component.* = switch (value) {
            .integer => |number| @floatFromInt(number),
            .real => |number| number,
            else => return error.InvalidFormMatrix,
        };
        if (!std.math.isFinite(component.*)) return error.InvalidFormMatrix;
    }
    return matrix;
}

fn formBBox(dict: Object.Dict) !layout.BBox {
    const object = dict.get("BBox") orelse return error.InvalidFormBBox;
    const array = switch (object) {
        .array => |array| array,
        else => return error.InvalidFormBBox,
    };
    if (array.len != 4) return error.InvalidFormBBox;
    var box: [4]f64 = undefined;
    for (array, &box) |value, *component| {
        component.* = switch (value) {
            .integer => |number| @floatFromInt(number),
            .real => |number| number,
            else => return error.InvalidFormBBox,
        };
        if (!std.math.isFinite(component.*)) return error.InvalidFormBBox;
    }
    if (box[0] > box[2] or box[1] > box[3]) return error.InvalidFormBBox;
    return .{ .x0 = box[0], .y0 = box[1], .x1 = box[2], .y1 = box[3] };
}

fn loadFormFonts(allocator: std.mem.Allocator, ctx: *const ExtractionContext, resources: Object.Dict, fonts: *std.StringHashMap(encoding.FontEncoding)) !void {
    const font_dict = try resolveContextDict(ctx, resources.get("Font") orelse return);
    for (font_dict.entries) |entry| {
        const dict = try resolveContextDict(ctx, entry.value);
        const Resolver = struct {
            context: *const ExtractionContext,
            failure: ?anyerror = null,
            fn resolve(raw_ctx: *const anyopaque, object: Object) Object {
                const resolver: *@This() = @ptrCast(@alignCast(@constCast(raw_ctx)));
                return resolveContextObject(resolver.context, object) catch |err| {
                    resolver.failure = err;
                    return .{ .null = {} };
                };
            }
        };
        var resolver = Resolver{ .context = ctx };
        var font = try encoding.parseFontEncoding(allocator, dict, Resolver.resolve, &resolver);
        if (resolver.failure) |err| {
            font.deinit();
            return err;
        }
        font.font_object_num = if (entry.value == .reference) entry.value.reference.num else null;
        const key = try std.fmt.allocPrint(allocator, "{d}:{s}", .{ ctx.page_num, entry.key });
        try fonts.put(key, font);
    }
}

fn formGraphicsState(state: @import("paint.zig").State, dict: Object.Dict) !@import("paint.zig").State {
    const paint_mod = @import("paint.zig");
    var clip = paint_mod.Tracker{ .state = state };
    clip.state.ctm = paint_mod.concat(state.ctm, try formMatrix(dict));
    const bbox = try formBBox(dict);
    clip.rectangle(bbox.x0, bbox.y0, bbox.x1 - bbox.x0, bbox.y1 - bbox.y0);
    clip.pending_clip = true;
    clip.endPath();
    return clip.state;
}

/// Shared Form resolution, resources and graphics framing for every text lane.
fn handleFormOperator(name: []const u8, maybe_ctx: ?*const ExtractionContext, mode: ExtractionMode, state: FormTextState, writer: anytype) anyerror!void {
    const ctx = maybe_ctx orelse return;
    const form = (try resolveForm(ctx, name)) orelse return;
    const traversal = ctx.traversal orelse return error.MissingFormTraversal;
    const scope = try traversal.enter(.{ .object_num = form.reference.num, .generation = form.reference.gen });
    defer traversal.leave();
    var arena = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const content = try decompress.decompressStream(scratch, form.stream.data, form.stream.dict.get("Filter"), form.stream.dict.get("DecodeParms"));
    if (ctx.selection_metrics) |metrics| metrics.form_xobjects_decoded += 1;
    var child = ctx.*;
    child.scratch_allocator = scratch;
    child.scope = scope;
    child.depth += 1;
    child.initial = state;
    child.initial.graphics = try formGraphicsState(state.graphics, form.stream.dict);
    var fonts = std.StringHashMap(encoding.FontEncoding).init(scratch);
    if (form.stream.dict.get("Resources")) |resource_object| {
        child.resources = try resolveContextDict(ctx, resource_object);
        try loadFormFonts(scratch, ctx, child.resources.?, &fonts);
        child.font_cache = &fonts;
    }
    const child_mode: ExtractionMode = switch (mode) {
        .stream => .{ .stream = .{ .resources = child.resources, .ctx = &child } },
        else => mode,
    };
    if (mode == .structured) {
        const saved_scope = mode.structured.stream_scope;
        defer mode.structured.setStreamScope(saved_scope);
        mode.structured.setStreamScope(form.reference);
        try extractContentStreamContext(content, child_mode, child.font_cache, child.page_num, scratch, writer, &child);
    } else {
        try extractContentStreamContext(content, child_mode, child.font_cache, child.page_num, scratch, writer, &child);
        // Permissively parsed Forms may omit ET. Font names still borrow the
        // child content, so own the pending span before releasing its arena.
        if (mode == .bounds) try mode.bounds.flush();
    }
}

fn writeTextWithFont(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, writer: anytype) !void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    if (font) |enc| {
        try enc.decode(data, writer);
    } else {
        try writeTextFallback(data, writer);
    }
}

fn writeTextToCollector(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, collector: *interpreter.SpanCollector) !void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    if (font) |enc| {
        try enc.decodeRecords(data, collector);
    } else {
        try collector.appendFallbackBytes(data);
    }
}

/// WinAnsi fallback decoding for text without font encoding
fn writeTextFallback(data: []const u8, writer: anytype) !void {
    for (data) |byte| {
        if (byte >= 32 and byte < 127) {
            try writer.writeByte(byte);
        } else if (byte == 0) {
            // CID separator
        } else {
            const codepoint = encoding.win_ansi_encoding[byte];
            if (codepoint != 0 and codepoint < 128) {
                try writer.writeByte(@truncate(codepoint));
            } else if (codepoint != 0) {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                try writer.writeAll(buf[0..len]);
            }
        }
    }
}

fn writeTJArrayWithFont(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, writer: anytype) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextWithFont(item, font, writer),
            .number => |n| {
                if (n < -100) {
                    try writer.writeByte(' ');
                }
            },
            else => {},
        }
    }
}

/// TJ array handler for SpanCollector (needs position tracking on spacing)
fn writeTJArrayToCollector(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, collector: *interpreter.SpanCollector) !void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => try writeTextToCollector(item, font, collector),
            .number => |n| {
                const adjustment = -n / 1000.0 * collector.current_font_size;
                try collector.advanceByTextAdjustment(adjustment);
            },
            else => {},
        }
    }
}

/// Extract MCID from a dictionary operand (for BDC)
fn extractMcidFromDict(operand: interpreter.Operand) ?i32 {
    switch (operand) {
        .array => |arr| {
            var i: usize = 0;
            while (i + 1 < arr.len) : (i += 1) {
                if (arr[i] == .name and std.mem.eql(u8, arr[i].name, "MCID")) {
                    if (arr[i + 1] == .number) {
                        return @intFromFloat(arr[i + 1].number);
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

/// Extract MCID from flattened BDC operands.
/// Supports:
/// 1. Array-shaped dictionary tokens
/// 2. Flattened name/value token pairs (... /MCID 12 ...)
fn extractMcidFromOperands(operands: []const interpreter.Operand, property_start: usize) ?i32 {
    if (property_start >= operands.len) return null;

    // First try existing array-based extraction on the property operand.
    if (extractMcidFromDict(operands[property_start])) |mcid| return mcid;

    // Fallback: scan flattened key/value pairs.
    var i = property_start;
    while (i + 1 < operands.len) : (i += 1) {
        if (operands[i] == .name and std.mem.eql(u8, operands[i].name, "MCID")) {
            if (operands[i + 1] == .number) {
                return @intFromFloat(operands[i + 1].number);
            }
        }
    }
    return null;
}

/// Write text to a fixed buffer (for MCID tracking in structured mode)
fn writeTextToBuffer(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, buf: []u8, pos: *usize) void {
    const data = switch (operand) {
        .string => |s| s,
        .hex_string => |s| s,
        else => return,
    };

    if (font) |enc| {
        var bw = BufferWriter{ .buf = buf, .pos = pos };
        enc.decode(data, &bw) catch {};
    } else {
        for (data) |byte| {
            if (pos.* >= buf.len) break;
            if (byte >= 32 and byte < 127) {
                buf[pos.*] = byte;
                pos.* += 1;
            } else if (byte != 0) {
                const codepoint = encoding.win_ansi_encoding[byte];
                if (codepoint != 0 and codepoint < 128) {
                    buf[pos.*] = @truncate(codepoint);
                    pos.* += 1;
                } else if (codepoint != 0) {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch continue;
                    for (utf8_buf[0..len]) |c| {
                        if (pos.* >= buf.len) break;
                        buf[pos.*] = c;
                        pos.* += 1;
                    }
                }
            }
        }
    }
}

/// Write TJ array to a fixed buffer (for MCID tracking in structured mode)
fn writeTJArrayToBuffer(operand: interpreter.Operand, font: ?*const encoding.FontEncoding, buf: []u8, pos: *usize) void {
    const arr = switch (operand) {
        .array => |a| a,
        else => return,
    };

    for (arr) |item| {
        switch (item) {
            .string, .hex_string => writeTextToBuffer(item, font, buf, pos),
            .number => |n| {
                if (n < -100 and pos.* < buf.len) {
                    buf[pos.*] = ' ';
                    pos.* += 1;
                }
            },
            else => {},
        }
    }
}

/// Simple buffer writer for font decoding into fixed buffers
const BufferWriter = struct {
    buf: []u8,
    pos: *usize,

    pub fn writeAll(self: *BufferWriter, data: []const u8) !void {
        for (data) |c| {
            if (self.pos.* >= self.buf.len) break;
            self.buf[self.pos.*] = c;
            self.pos.* += 1;
        }
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        if (self.pos.* < self.buf.len) {
            self.buf[self.pos.*] = byte;
            self.pos.* += 1;
        }
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
        _ = self;
    }
};

/// No-op writer used as a dummy when the writer parameter is unused (structured mode)
const NullWriter = struct {
    pub fn writeAll(_: *NullWriter, _: []const u8) !void {}
    pub fn writeByte(_: *NullWriter, _: u8) !void {}
    pub fn print(_: *NullWriter, comptime _: []const u8, _: anytype) !void {}
};

// ============================================================================
// CONVENIENCE FUNCTIONS
// ============================================================================

/// Extract text from a PDF file to a string
pub fn extractTextFromFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const doc = try Document.open(allocator, path);
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try doc.extractAllText(runtime.arrayListWriter(&output, allocator));

    return output.toOwnedSlice(allocator);
}

/// Extract text from a PDF in memory to a string
pub fn extractTextFromMemory(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const doc = try Document.openFromMemory(allocator, data, ErrorConfig.default());
    defer doc.close();

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try doc.extractAllText(runtime.arrayListWriter(&output, allocator));

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "ErrorConfig presets" {
    const strict = ErrorConfig.strict();
    try std.testing.expectEqual(@as(u32, 0), strict.max_errors);

    const permissive = ErrorConfig.permissive();
    try std.testing.expect(permissive.continue_on_parse_error);
}

test "ActualText replaces marked-content glyph text in stream mode" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const content = "BT /Span << /ActualText (Correct text) /MCID 7 >> BDC (bad) Tj EMC ET";
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try extractContentStream(content, .{ .stream = .{ .resources = null, .ctx = null } }, &fonts, 0, scratch.allocator(), runtime.arrayListWriter(&output, allocator));

    try std.testing.expectEqualStrings("Correct text", output.items);
}

test "ActualText preserves glyph-derived bbox in bounds mode" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const content = "BT /F1 10 Tf 10 20 Td /Span << /ActualText (office) /MCID 3 >> BDC (xx) Tj EMC ET";
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();
    var enc = encoding.FontEncoding.init(allocator);
    enc.widths.simple_widths['x'] = 500;
    try fonts.put("0:F1", enc);
    defer {
        var value = fonts.getPtr("0:F1").?;
        value.deinit();
    }

    var collector = interpreter.SpanCollector.init(allocator, 0);
    defer collector.deinit();
    var nw: NullWriter = .{};
    try extractContentStream(content, .{ .bounds = &collector }, &fonts, 0, scratch.allocator(), &nw);
    try collector.flush();

    const spans = collector.getSpans();
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("office", spans[0].text);
    try std.testing.expect(spans[0].actual_text);
    try std.testing.expect(spans[0].bbox.x1 > spans[0].bbox.x0);
    try std.testing.expectEqual(@as(?i32, 3), spans[0].mcid);
}

fn collectActualTextTest(allocator: std.mem.Allocator, content: []const u8) !interpreter.SpanCollector {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();
    var collector = interpreter.SpanCollector.init(allocator, 0);
    errdefer collector.deinit();
    var writer: NullWriter = .{};
    try extractContentStream(content, .{ .bounds = &collector }, &fonts, 0, scratch.allocator(), &writer);
    try collector.flush();
    return collector;
}

test "ActualText scope projects once across text font and paint runs while retaining raw evidence" {
    const allocator = std.testing.allocator;
    var collector = try collectActualTextTest(allocator, "BT /F1 10 Tf 10 20 Td /Span << /ActualText (semantic words) /MCID 4 >> BDC (raw) Tj /F2 15 Tf [(glyphs) -300 (more)] TJ 3 Tr (ink) Tj EMC ET");
    defer collector.deinit();
    const projected = try collector.toOwnedSemanticGlyphSlice();
    defer Document.freeGlyphSpans(allocator, projected);
    try std.testing.expectEqual(@as(usize, 1), collector.actual_text_runs.items.len);
    try std.testing.expectEqual(@as(usize, 1), collector.spans.items.len);
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("semantic words", projected[0].text);
    try std.testing.expectEqualStrings("semantic words", collector.spans.items[0].text);
    try std.testing.expectEqual(@as(?i32, 4), projected[0].mcid);
    try std.testing.expectEqual(@as(u8, 'r'), collector.glyphs.items[0].text[0]);
    try std.testing.expectEqual(encoding.MappingSource.simple_encoding, collector.glyphs.items[0].mapping_source);
    try std.testing.expectEqual(encoding.MappingSource.actual_text, projected[0].mapping_source);
    try std.testing.expect(projected[0].semantic_replacement);
    try std.testing.expectEqual(@as(u32, @intCast(collector.glyphs.items.len)), projected[0].raw_glyph_count);
    try std.testing.expectEqual(.unknown, projected[0].paint.paint_state);
    try std.testing.expectEqual(@as(?[]const u8, null), projected[0].font_name);
    var union_bbox = collector.glyphs.items[0].bbox;
    for (collector.glyphs.items[1..]) |glyph| {
        union_bbox.x0 = @min(union_bbox.x0, glyph.bbox.x0);
        union_bbox.y0 = @min(union_bbox.y0, glyph.bbox.y0);
        union_bbox.x1 = @max(union_bbox.x1, glyph.bbox.x1);
        union_bbox.y1 = @max(union_bbox.y1, glyph.bbox.y1);
    }
    try std.testing.expectEqual(union_bbox, projected[0].bbox);
    try std.testing.expect(projected[0].text.ptr != collector.actual_text_runs.items[0].text.ptr);
}

test "ActualText empty replacements suppress raw ranges and nested outer scope owns replacement" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { content: []const u8, expected: []const u8, projected_count: usize }{
        .{ .content = "BT /F1 10 Tf /Span << /ActualText () >> BDC (hidden) Tj EMC (shown) Tj ET", .expected = "shown", .projected_count = 5 },
        .{ .content = "BT /F1 10 Tf /Span << /ActualText (Outer) >> BDC (a) Tj /Span << /ActualText (Inner) >> BDC (b) Tj EMC (c) Tj EMC ET", .expected = "Outer", .projected_count = 1 },
        .{ .content = "BT /F1 10 Tf /Span << /ActualText () >> BDC (a) Tj /Span << /ActualText (Inner) >> BDC (b) Tj EMC (c) Tj EMC ET", .expected = "", .projected_count = 0 },
    };
    for (cases) |case| {
        var collector = try collectActualTextTest(allocator, case.content);
        defer collector.deinit();
        const projected = try collector.toOwnedSemanticGlyphSlice();
        defer Document.freeGlyphSpans(allocator, projected);
        try std.testing.expectEqual(case.projected_count, projected.len);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (projected) |glyph| try text.appendSlice(allocator, glyph.text);
        try std.testing.expectEqualStrings(case.expected, text.items);
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
        defer fonts.deinit();
        text.clearRetainingCapacity();
        try extractContentStream(case.content, .{ .stream = .{ .resources = null, .ctx = null } }, &fonts, 0, scratch.allocator(), runtime.arrayListWriter(&text, allocator));
        try std.testing.expectEqualStrings(case.expected, text.items);
    }
}

test "ActualText Unicode and multiline replacement stays one authoritative scope" {
    const allocator = std.testing.allocator;
    var collector = try collectActualTextTest(allocator, "BT /F1 10 Tf /Span << /ActualText <FEFF006503010020D83DDE00000A0042> >> BDC (x) Tj 20 TL T* (y) Tj EMC ET");
    defer collector.deinit();
    const projected = try collector.toOwnedSemanticGlyphSlice();
    defer Document.freeGlyphSpans(allocator, projected);
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("e\u{301} 😀\nB", projected[0].text);
    try std.testing.expectEqualStrings("e\u{301} 😀\nB", collector.spans.items[0].text);
}

test "ActualText child content cannot close an inherited enclosing replacement" {
    const allocator = std.testing.allocator;
    var collector = interpreter.SpanCollector.init(allocator, 0);
    defer collector.deinit();
    try collector.setActualText("Outer");
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();
    var writer: NullWriter = .{};
    try extractContentStream("BT /F1 10 Tf /Span << /ActualText (Inner) >> BDC (raw) Tj EMC ET", .{ .bounds = &collector }, &fonts, 0, scratch.allocator(), &writer);
    try std.testing.expectEqual(@as(usize, 0), collector.actual_text_runs.items.len);
    try std.testing.expectEqualStrings("Outer", collector.current_actual_text.?);
    try collector.setActualText(null);
    const projected = try collector.toOwnedSemanticGlyphSlice();
    defer Document.freeGlyphSpans(allocator, projected);
    try std.testing.expectEqual(@as(usize, 1), projected.len);
    try std.testing.expectEqualStrings("Outer", projected[0].text);
}

test "ActualText identical sibling replacements retain distinct scope runs" {
    const allocator = std.testing.allocator;
    var collector = try collectActualTextTest(allocator, "BT /F1 10 Tf /Span << /ActualText (X) >> BDC (a) Tj EMC /Span << /ActualText (X) >> BDC (b) Tj EMC ET");
    defer collector.deinit();
    const projected = try collector.toOwnedSemanticGlyphSlice();
    defer Document.freeGlyphSpans(allocator, projected);
    try std.testing.expectEqual(@as(usize, 2), collector.actual_text_runs.items.len);
    try std.testing.expectEqual(@as(usize, 2), projected.len);
    try std.testing.expectEqualStrings("X", projected[0].text);
    try std.testing.expectEqualStrings("X", projected[1].text);
    try std.testing.expectEqual(@as(?u32, 0), projected[0].raw_glyph_start);
    try std.testing.expectEqual(@as(?u32, 1), projected[1].raw_glyph_start);
    try std.testing.expectEqual(@as(?u32, 0), projected[0].semantic_run_id);
    try std.testing.expectEqual(@as(?u32, 1), projected[1].semantic_run_id);
}

fn actualTextProjectionAllocationProbe(allocator: std.mem.Allocator) !void {
    var collector = try collectActualTextTest(allocator, "BT /F1 10 Tf /Span << /ActualText (long semantic replacement) >> BDC (a) Tj /F2 12 Tf [(b) -300 (c)] TJ EMC /Span << /ActualText () >> BDC (d) Tj EMC (e) Tj ET");
    defer collector.deinit();
    const projected = try collector.toOwnedSemanticGlyphSlice();
    defer Document.freeGlyphSpans(allocator, projected);
    try std.testing.expectEqual(@as(usize, 2), projected.len);
    try std.testing.expectEqualStrings("long semantic replacement", projected[0].text);
    try std.testing.expectEqualStrings("e", projected[1].text);
}

test "ActualText semantic projection ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, actualTextProjectionAllocationProbe, .{});
}

test "text line translations follow the linear text matrix" {
    var collector = try collectActualTextTest(std.testing.allocator, "BT /F1 10 Tf 0 1 -1 0 100 100 Tm (A) Tj 0 -20 Td (B) Tj 20 TL T* (C) Tj ET");
    defer collector.deinit();
    try std.testing.expectEqual(@as(f64, 100), collector.glyphs.items[0].text_matrix[4]);
    try std.testing.expectEqual(@as(f64, 120), collector.glyphs.items[1].text_matrix[4]);
    try std.testing.expectEqual(@as(f64, 140), collector.glyphs.items[2].text_matrix[4]);
    for (collector.glyphs.items) |glyph| try std.testing.expectEqual(@as(f64, 100), glyph.text_matrix[5]);
}

fn collectPaintTestGeometry(content: []const u8) !NativePageGeometry {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();
    var collector = interpreter.SpanCollector.init(allocator, 0);
    defer collector.deinit();
    var writer: NullWriter = .{};
    try extractContentStream(content, .{ .bounds = &collector }, &fonts, 0, scratch.allocator(), &writer);
    try collector.flush();
    const spans = try collector.toOwnedSlice();
    errdefer Document.freeTextSpans(allocator, spans);
    return .{ .allocator = allocator, .spans = spans, .glyphs = try collector.toOwnedGlyphSlice() };
}

fn formTraversalPdf(allocator: std.mem.Allocator, page_content: []const u8, form_content: []const u8, form_extra: []const u8) ![]u8 {
    return formTraversalPdfWithPageFont(allocator, page_content, form_content, form_extra, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
}

fn formTraversalPdfWithPageFont(allocator: std.mem.Allocator, page_content: []const u8, form_content: []const u8, form_extra: []const u8, page_font: []const u8) ![]u8 {
    const page_stream = try std.fmt.allocPrint(allocator, "<< /Length {} >>\nstream\n{s}\nendstream", .{ page_content.len, page_content });
    defer allocator.free(page_stream);
    const form_stream = try std.fmt.allocPrint(allocator, "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] {s} /Length {} >>\nstream\n{s}\nendstream", .{ form_extra, form_content.len, form_content });
    defer allocator.free(form_stream);
    const objects = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /Font << /F1 4 0 R /F2 8 0 R >> /XObject << /Fm 6 0 R /Im 10 0 R >> /Properties << /P1 << /ActualText (Page named) /MCID 0 >> >> >> /Contents 5 0 R >>",
        page_font,
        page_stream,
        form_stream,
        "<< /Font << /F1 8 0 R /F2 4 0 R >> /XObject << /Fm 6 0 R /Im 10 0 R >> /Properties << /P1 9 0 R >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /B] >> >>",
        "<< /ActualText (Form named) /MCID 0 >>",
        "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length 3 >>\nstream\n\x00\x00\x00\nendstream",
    };
    var pdf: std.ArrayList(u8) = .empty;
    errdefer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);
    try writer.writeAll("%PDF-1.4\n");
    var offsets: [objects.len]usize = undefined;
    for (objects, 0..) |object, index| {
        offsets[index] = pdf.items.len;
        try writer.print("{} 0 obj\n{s}\nendobj\n", .{ index + 1, object });
    }
    const xref_offset = pdf.items.len;
    try writer.print("xref\n0 {}\n0000000000 65535 f \n", .{objects.len + 1});
    for (offsets) |offset| try writer.print("{d:0>10} 00000 n \n", .{offset});
    try writer.print("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n", .{ objects.len + 1, xref_offset });
    return pdf.toOwnedSlice(allocator);
}

test "vector evidence Form placements apply matrix once and preserve scoped clip" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "q 1 0 0 1 20 50 cm /Fm Do Q q 1 0 0 1 100 50 cm /Fm Do Q /Im Do", "1 2 3 4 re f 200 200 2 2 re f", "/Resources 7 0 R /Matrix [2 0 0 3 10 20]");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var evidence = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "q 1 0 0 1 20 50 cm /Fm Do Q q 1 0 0 1 100 50 cm /Fm Do Q /Im Do");
    defer evidence.deinit();
    try std.testing.expectEqual(.complete, evidence.status);
    try std.testing.expectEqual(@as(usize, 4), evidence.shapes.len);
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = 32, .y0 = 76, .x1 = 38, .y1 = 88 }, evidence.shapes[0].bbox);
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = 112, .y0 = 76, .x1 = 118, .y1 = 88 }, evidence.shapes[2].bbox);
    try std.testing.expectEqual(.inside, evidence.shapes[0].clip_state);
    try std.testing.expectEqual(.outside, evidence.shapes[1].clip_state);
    try std.testing.expectEqual(@as(?u32, 6), evidence.shapes[0].content_scope.?.stream_object_num);
    try std.testing.expect(evidence.shapes[0].content_scope.?.invocation_index != evidence.shapes[2].content_scope.?.invocation_index);
}

test "vector evidence Form cycles are partial and invocation operator caps are shared" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "/Fm Do", "0 0 2 2 re f /Fm Do", "/Resources 7 0 R");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var cycle = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "/Fm Do");
    defer cycle.deinit();
    try std.testing.expectEqual(.partial, cycle.status);
    try std.testing.expectEqual(@as(usize, 1), cycle.shapes.len);
    var limited = try doc.getPageVectorEvidenceFromContentWithLimits(0, allocator, allocator, "/Fm Do /Fm Do", .{ .max_form_invocations = 1 });
    defer limited.deinit();
    try std.testing.expectEqual(.limited, limited.status);
    try std.testing.expectEqual(@as(usize, 1), limited.shapes.len);
    var ops = try doc.getPageVectorEvidenceFromContentWithLimits(0, allocator, allocator, "/Fm Do", .{ .max_operators = 2 });
    defer ops.deinit();
    try std.testing.expectEqual(.limited, ops.status);
    try std.testing.expectEqual(@as(u32, 2), ops.operator_count);
    try std.testing.expectEqual(@as(usize, 0), ops.shapes.len);
    var bytes_limited = try doc.getPageVectorEvidenceFromContentWithLimits(0, allocator, allocator, "/Fm Do", .{ .max_content_bytes = 6 });
    defer bytes_limited.deinit();
    try std.testing.expectEqual(.limited, bytes_limited.status);
    try std.testing.expectEqual(@as(u32, 6), bytes_limited.content_bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes_limited.shapes.len);
}

fn vectorFormAllocationProbe(allocator: std.mem.Allocator, doc: *Document) !void {
    var evidence = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "q 1 0 0 1 20 50 cm /Fm Do Q /Fm Do");
    defer evidence.deinit();
    try std.testing.expectEqual(@as(usize, 2), evidence.shapes.len);
}

test "vector evidence unresolved Do is partial while known images are ignored" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "/Missing Do /Im Do", "0 0 2 2 re f", "");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var missing = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "/Missing Do");
    defer missing.deinit();
    try std.testing.expectEqual(.partial, missing.status);
    try std.testing.expectEqual(@as(u32, 1), missing.unknown_count);
    var image = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "/Im Do");
    defer image.deinit();
    try std.testing.expectEqual(.complete, image.status);
    try std.testing.expectEqual(@as(usize, 0), image.shapes.len);
    const resources = doc.pages.items[0].resources;
    defer doc.pages.items[0].resources = resources;
    doc.pages.items[0].resources = null;
    var absent = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "/Fm Do");
    defer absent.deinit();
    try std.testing.expectEqual(.partial, absent.status);
    try std.testing.expectEqual(@as(u32, 1), absent.unknown_count);
}

test "vector evidence malformed numeric bytes cannot become synthetic zero coordinates" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "", "", "");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    for ([_][]const u8{ "+ 0 2 3 re f", "0 0 - 3 re f", "0 0 . 3 re f" }) |content| {
        var evidence = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, content);
        defer evidence.deinit();
        try std.testing.expectEqual(.partial, evidence.status);
        try std.testing.expectEqual(@as(usize, 0), evidence.shapes.len);
    }
    var valid = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "% ignored numeric comment 123\n -1 .5 2 3 re f");
    defer valid.deinit();
    try std.testing.expectEqual(.complete, valid.status);
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = -1, .y0 = 0.5, .x1 = 1, .y1 = 3.5 }, valid.shapes[0].bbox);
}

test "vector evidence Form frames free partial output at every allocation failure" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "/Fm Do", "1 2 3 4 re f", "/Resources 7 0 R /Matrix [2 0 0 3 10 20]");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var warmup = try doc.getPageVectorEvidenceFromContent(0, allocator, allocator, "/Fm Do");
    warmup.deinit();
    try std.testing.checkAllAllocationFailures(allocator, vectorFormAllocationProbe, .{doc});
}

test "Form traversal resolves scoped named ActualText and preserves inherited page resources" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "", "/Resources 7 0 R" }) |resources| {
        const bytes = try formTraversalPdf(allocator, "BT /F1 12 Tf 20 280 Td /Span /P1 BDC (A) Tj EMC ET /Fm Do", "BT /F1 12 Tf 5 8 Td /Span /P1 BDC (A) Tj EMC ET", resources);
        defer allocator.free(bytes);
        const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
        defer doc.close();
        const raw = try doc.extractTextRawRecall(0, allocator);
        defer allocator.free(raw);
        const expected = if (resources.len == 0) "Page namedPage named" else "Page namedForm named";
        try std.testing.expectEqualStrings(expected, raw);
        const fast_page = try doc.extractTextFast(0, allocator);
        defer allocator.free(fast_page);
        try std.testing.expectEqualStrings(expected, fast_page);
        const fast_all = try doc.extractAllTextFast(allocator);
        defer allocator.free(fast_all);
        try std.testing.expectEqualStrings(expected, fast_all);
        var geometry = try doc.extractNativePageGeometry(0, allocator);
        defer geometry.deinit();
        try std.testing.expectEqual(@as(usize, 2), geometry.spans.len);
        try std.testing.expectEqualStrings("Page named", geometry.spans[0].text);
        try std.testing.expectEqualStrings(if (resources.len == 0) "Page named" else "Form named", geometry.spans[1].text);
        try std.testing.expectEqual(@as(?u32, 6), geometry.glyphs[1].content_scope.?.stream_object_num);
        try std.testing.expectEqualStrings(if (resources.len == 0) "A" else "B", geometry.glyphs[1].text);
    }
}

test "Form traversal cycles and unresolved properties fail all observable native lanes" {
    const allocator = std.testing.allocator;
    for ([_]struct { content: []const u8, failure: anyerror }{
        .{ .content = "/Fm Do", .failure = error.FormCycleDetected },
        .{ .content = "BT /F1 12 Tf /Span /Missing BDC (A) Tj EMC ET", .failure = error.MissingMarkedContentProperty },
    }) |case| {
        const bytes = try formTraversalPdf(allocator, "/Fm Do", case.content, "/Resources 7 0 R");
        defer allocator.free(bytes);
        const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
        defer doc.close();
        try std.testing.expectError(case.failure, doc.extractNativePageGeometry(0, allocator));
        try std.testing.expectError(case.failure, doc.extractTextRawRecall(0, allocator));
        try std.testing.expectError(case.failure, doc.extractTextFast(0, allocator));
        try std.testing.expectError(case.failure, doc.extractAllTextFast(allocator));
    }
}

test "aggregate fast extraction resolves named properties separately on each page" {
    const allocator = std.testing.allocator;
    const content = "BT /F1 12 Tf 20 280 Td /Tag /Property BDC (WRONGVISIBLE) Tj EMC ET";
    const stream_object = try std.fmt.allocPrint(allocator, "<< /Length {} >>\nstream\n{s}\nendstream", .{ content.len, content });
    defer allocator.free(stream_object);
    const objects = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /Font << /F1 5 0 R >> /Properties << /Property << /ActualText (Page one) /MCID 0 >> >> >> /Contents 6 0 R >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources 8 0 R /Contents 7 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        stream_object,
        stream_object,
        "<< /Font << /F1 5 0 R >> /Properties << /Property 9 0 R >> >>",
        "<< /ActualText (Page two) /MCID 0 >>",
    };
    var pdf: std.ArrayList(u8) = .empty;
    defer pdf.deinit(allocator);
    var writer = runtime.arrayListWriter(&pdf, allocator);
    try writer.writeAll("%PDF-1.4\n");
    var offsets: [objects.len]usize = undefined;
    for (objects, 0..) |object, index| {
        offsets[index] = pdf.items.len;
        try writer.print("{} 0 obj\n{s}\nendobj\n", .{ index + 1, object });
    }
    const xref_offset = pdf.items.len;
    try writer.print("xref\n0 {}\n0000000000 65535 f \n", .{objects.len + 1});
    for (offsets) |offset| try writer.print("{d:0>10} 00000 n \n", .{offset});
    try writer.print("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n", .{ objects.len + 1, xref_offset });
    const doc = try Document.openFromMemory(allocator, pdf.items, ErrorConfig.default());
    defer doc.close();
    for ([_][]const u8{ "Page one", "Page two" }, 0..) |expected, page_num| {
        const page = try doc.extractTextFast(page_num, allocator);
        defer allocator.free(page);
        try std.testing.expectEqualStrings(expected, page);
    }
    const aggregate = try doc.extractAllTextFast(allocator);
    defer allocator.free(aggregate);
    try std.testing.expectEqualStrings("Page one\x0cPage two", aggregate);
    const through_mode = try doc.extractAllTextWithMode(allocator, .fast);
    defer allocator.free(through_mode);
    try std.testing.expectEqualStrings(aggregate, through_mode);
}

fn formGeometryAllocationProbe(allocator: std.mem.Allocator, doc: *Document, content: []const u8) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var geometry = try doc.extractNativePageGeometryFromContent(0, allocator, scratch.allocator(), content);
    defer geometry.deinit();
    try std.testing.expectEqual(@as(usize, 2), geometry.spans.len);
}

test "Form traversal resource frames free partial geometry on every allocation failure" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "q 1 0 0 1 20 50 cm /Fm Do Q q 1 0 0 1 100 50 cm /Fm Do Q", "BT /F1 12 Tf 5 8 Td (A) Tj ET", "/Resources 7 0 R /Matrix [2 0 0 2 10 20]");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const content = try doc.getPageContentForScratch(0, scratch.allocator());
    var warmup = try doc.extractNativePageGeometryFromContent(0, allocator, scratch.allocator(), content);
    warmup.deinit();
    try std.testing.checkAllAllocationFailures(allocator, formGeometryAllocationProbe, .{ doc, content });
}

test "Form traversal invocation cap cannot publish extra placements" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "/Fm Do /Fm Do /Fm Do", "BT /F1 12 Tf (A) Tj ET", "");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    doc.ensurePageFonts(0);
    const content = try doc.getPageContentForScratch(0, scratch.allocator());
    var traversal = form_scope.Traversal{ .page_index = 0, .max_invocations = 2 };
    const context = doc.contentContext(0, scratch.allocator(), &traversal);
    var collector = interpreter.SpanCollector.init(allocator, 0);
    defer collector.deinit();
    var writer: NullWriter = .{};
    try std.testing.expectError(error.FormInvocationLimitExceeded, extractContentStreamContext(content, .{ .bounds = &collector }, &doc.font_cache, 0, scratch.allocator(), &writer, &context));
    try std.testing.expectEqual(@as(usize, 2), collector.glyphs.items.len);
    try std.testing.expectEqual(@as(usize, 0), traversal.depth);
}

test "Form traversal restores q Q fonts in recall geometry and structured modes" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "/Fm Do", "BT /F1 12 Tf /Span << /MCID 0 >> BDC (A) Tj q /F2 12 Tf (A) Tj Q (A) Tj EMC ET", "/Resources 7 0 R");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    const raw = try doc.extractTextRawRecall(0, allocator);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("BAB", raw);
    var geometry = try doc.extractNativePageGeometry(0, allocator);
    defer geometry.deinit();
    for (geometry.glyphs, "BAB") |glyph, expected| try std.testing.expectEqual(expected, glyph.text[0]);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const content = try doc.getPageContentForScratch(0, scratch.allocator());
    var traversal = form_scope.Traversal{ .page_index = 0 };
    const context = doc.contentContext(0, scratch.allocator(), &traversal);
    var extractor = structtree.MarkedContentExtractor.init(allocator);
    defer extractor.deinit();
    var writer: NullWriter = .{};
    try extractContentStreamContext(content, .{ .structured = &extractor }, &doc.font_cache, 0, scratch.allocator(), &writer, &context);
    try std.testing.expectEqualStrings("BAB", extractor.getTextForScopedMcid(.{ .num = 6, .gen = 0 }, 0).?);
    try std.testing.expect(extractor.getTextForMcid(0) == null);
}

test "Form traversal cold recall resolves encoded page fonts and inherited Form resources" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdfWithPageFont(allocator, "BT /F1 12 Tf (A) Tj ET q BT /F2 12 Tf (A) Tj ET Q BT (A) Tj ET /Fm Do", "BT /F1 12 Tf (A) Tj ET", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /Z] >> >>");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    try std.testing.expectEqual(@as(u32, 0), doc.font_cache.count());
    const cold = try doc.extractTextRawRecall(0, allocator);
    defer allocator.free(cold);
    try std.testing.expectEqualStrings("ZBZZ", cold);
    var geometry = try doc.extractNativePageGeometry(0, allocator);
    defer geometry.deinit();
    for (geometry.glyphs, "ZBZZ") |glyph, expected| try std.testing.expectEqual(expected, glyph.text[0]);
    const warm = try doc.extractTextRawRecall(0, allocator);
    defer allocator.free(warm);
    try std.testing.expectEqualStrings(cold, warm);
}

test "Form traversal image inventory applies nested placement matrix and Form bbox" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "q 1 0 0 1 20 50 cm /Fm Do Q", "q 60 0 0 80 10 10 cm /Im Do Q q 60 0 0 80 200 200 cm /Im Do Q", "/Resources 7 0 R /Matrix [2 0 0 2 10 20]");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    const images = try doc.getPageImages(0, allocator);
    defer Document.freeImages(allocator, images);
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualSlices(f64, &.{ 50, 90, 170, 250 }, &images[0].rect);
}

test "Form traversal owns pending span metadata before an unterminated child frame exits" {
    const allocator = std.testing.allocator;
    const bytes = try formTraversalPdf(allocator, "/Fm Do", "BT /F1 12 Tf (A) Tj", "/Resources 7 0 R");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    var geometry = try doc.extractNativePageGeometry(0, allocator);
    defer geometry.deinit();
    try std.testing.expectEqual(@as(usize, 1), geometry.spans.len);
    try std.testing.expectEqualStrings("B", geometry.spans[0].text);
    try std.testing.expectEqualStrings("F1", geometry.spans[0].font.name.?);
    try std.testing.expectEqual(@as(?u32, 6), geometry.spans[0].content_scope.?.stream_object_num);
}

test "native paint modes preserve raw hidden text and restore q Q state" {
    var geometry = try collectPaintTestGeometry("BT /Ordinary 10 Tf (A) Tj q 3 Tr /Ordinary 20 Tf (B) Tj Q (C) Tj 7 Tr (D) Tj ET");
    defer geometry.deinit();
    try std.testing.expectEqual(@as(usize, 4), geometry.spans.len);
    const expected_modes = [_]u8{ 0, 3, 0, 7 };
    for (geometry.spans, expected_modes, "ABCD") |span, mode, byte| {
        try std.testing.expectEqual(@as(?u8, mode), span.paint.rendering_mode);
        const expected_state: @TypeOf(span.paint.paint_state) = if (mode == 3 or mode == 7) .non_painting else .painting;
        try std.testing.expectEqual(expected_state, span.paint.paint_state);
        try std.testing.expectEqual(layout.SourceKind.native_pdf, span.source);
        try std.testing.expectEqual(byte, span.text[0]);
    }
    try std.testing.expectEqual(@as(f64, 10), geometry.spans[2].font_size);
    for (geometry.glyphs, geometry.spans) |glyph, span| try std.testing.expect(std.meta.eql(glyph.paint, span.paint));
}

test "native rectangular clip evidence retains inside outside and partial text" {
    const cases = [_]struct { x: u8, expected: @TypeOf((layout.PaintEvidence{}).clip_state) }{
        .{ .x = 5, .expected = .inside },
        .{ .x = 30, .expected = .outside },
        .{ .x = 18, .expected = .partial },
    };
    for (cases) |case| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "0 0 20 40 re W n BT /Ordinary 10 Tf 1 0 0 1 {d} 10 Tm (A) Tj ET", .{case.x});
        defer std.testing.allocator.free(content);
        var geometry = try collectPaintTestGeometry(content);
        defer geometry.deinit();
        try std.testing.expectEqual(@as(usize, 1), geometry.spans.len);
        try std.testing.expectEqualStrings("A", geometry.spans[0].text);
        try std.testing.expectEqual(case.expected, geometry.spans[0].paint.clip_state);
        try std.testing.expectEqual(@as(f64, 20), geometry.spans[0].paint.clip_bbox.?.x1);
    }
}

test "native transformed clip and glyph geometry share PDF user space" {
    var geometry = try collectPaintTestGeometry("2 0 0 2 100 200 cm 0 0 40 40 re W* n BT /Ordinary 10 Tf 1 0 0 1 5 10 Tm (A) Tj ET");
    defer geometry.deinit();
    const span = geometry.spans[0];
    try std.testing.expectEqual(.inside, span.paint.clip_state);
    try std.testing.expectEqual(@as(f64, 110), span.bbox.x0);
    try std.testing.expectEqual(@as(f64, 100), span.paint.clip_bbox.?.x0);
    try std.testing.expectEqual(@as(f64, 280), span.paint.clip_bbox.?.y1);
    try std.testing.expectEqual(@as(f64, 2), geometry.glyphs[0].text_matrix[0]);
}

test "native clip state changes only at path end and restores across q Q" {
    var geometry = try collectPaintTestGeometry("q 0 0 20 40 re W BT /Ordinary 10 Tf 1 0 0 1 30 10 Tm (A) Tj ET n BT /Ordinary 10 Tf 1 0 0 1 30 10 Tm (B) Tj ET Q BT /Ordinary 10 Tf 1 0 0 1 30 10 Tm (C) Tj ET");
    defer geometry.deinit();
    try std.testing.expectEqual(@as(usize, 3), geometry.spans.len);
    try std.testing.expectEqual(.unclipped, geometry.spans[0].paint.clip_state);
    try std.testing.expectEqual(.outside, geometry.spans[1].paint.clip_state);
    try std.testing.expectEqual(.unclipped, geometry.spans[2].paint.clip_state);
}

test "native arbitrary and text clips preserve uncertain state" {
    const cases = [_][]const u8{
        "0 0 m 20 0 l 20 20 l h W n BT /Ordinary 10 Tf (A) Tj ET",
        "1 1 -1 1 0 0 cm 0 0 20 40 re W n BT /Ordinary 10 Tf (A) Tj ET",
        "BT /Ordinary 10 Tf 7 Tr (X) Tj ET BT 0 Tr (A) Tj ET",
        "0 0 20 40 re W n /Invalid 0 0 1 0 0 cm BT /Ordinary 10 Tf (A) Tj ET",
    };
    for (cases) |content| {
        var geometry = try collectPaintTestGeometry(content);
        defer geometry.deinit();
        const span = geometry.spans[geometry.spans.len - 1];
        try std.testing.expectEqual(.unknown, span.paint.clip_state);
        try std.testing.expectEqual(@as(?layout.BBox, null), span.paint.clip_bbox);
        try std.testing.expectEqualStrings("A", span.text);
    }
}

test "native Type3 rendering modes remain uncertain and do not fabricate text clipping" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();
    var type3 = encoding.FontEncoding.init(allocator);
    type3.is_type3 = true;
    try fonts.put("0:FType3", type3);
    defer fonts.getPtr("0:FType3").?.deinit();
    var collector = interpreter.SpanCollector.init(allocator, 0);
    defer collector.deinit();
    var writer: NullWriter = .{};
    try extractContentStream("BT 3 Tr /Ordinary 10 Tf (A) Tj /FType3 10 Tf 0 Tr (B) Tj 7 Tr (C) Tj ET BT 0 Tr /Ordinary 10 Tf (D) Tj ET", .{ .bounds = &collector }, &fonts, 0, scratch.allocator(), &writer);
    try collector.flush();
    const spans = collector.getSpans();
    try std.testing.expectEqual(@as(usize, 4), spans.len);
    try std.testing.expectEqual(.non_painting, spans[0].paint.paint_state);
    try std.testing.expectEqual(.unknown, spans[1].paint.paint_state);
    try std.testing.expectEqual(.non_painting, spans[2].paint.paint_state);
    try std.testing.expectEqual(@as(?u8, 7), spans[2].paint.rendering_mode);
    try std.testing.expectEqual(.painting, spans[3].paint.paint_state);
    try std.testing.expectEqual(.unclipped, spans[3].paint.clip_state);
}

fn paintCollectorAllocationProbe(allocator: std.mem.Allocator) !void {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var fonts = std.StringHashMap(encoding.FontEncoding).init(allocator);
    defer fonts.deinit();
    var collector = interpreter.SpanCollector.init(allocator, 0);
    defer collector.deinit();
    var writer: NullWriter = .{};
    try extractContentStream("q 0 0 100 100 re W n BT /Ordinary 10 Tf (A) Tj q 3 Tr (B) Tj Q (C) Tj ET Q", .{ .bounds = &collector }, &fonts, 0, scratch.allocator(), &writer);
    try collector.flush();
}

test "native paint state ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, paintCollectorAllocationProbe, .{});
}

test "image placement restores independent q Q transformations" {
    const allocator = std.testing.allocator;
    const data = try @import("testpdf.zig").generateImagePdf(allocator);
    defer allocator.free(data);
    const doc = try Document.openFromMemory(allocator, data, ErrorConfig.default());
    defer doc.close();
    const images = try doc.getPageImagesFromContent(0, allocator, allocator, "q 40 0 0 40 20 20 cm /Im1 Do Q q 40 0 0 40 120 20 cm /Im1 Do Q");
    defer Document.freeImages(allocator, images);
    try std.testing.expectEqual(@as(usize, 2), images.len);
    try std.testing.expectEqual([4]f64{ 20, 20, 60, 60 }, images[0].rect);
    try std.testing.expectEqual([4]f64{ 120, 20, 160, 60 }, images[1].rect);
}

test "image placement uses all affine corners and nested concatenation" {
    const allocator = std.testing.allocator;
    const data = try @import("testpdf.zig").generateImagePdf(allocator);
    defer allocator.free(data);
    const doc = try Document.openFromMemory(allocator, data, ErrorConfig.default());
    defer doc.close();
    const images = try doc.getPageImagesFromContent(0, allocator, allocator, "q 0 40 -20 0 100 20 cm /Im1 Do Q q 2 0 0 3 10 20 cm q 0 40 -20 0 100 20 cm /Im1 Do Q Q q 40 20 -10 30 50 60 cm /Im1 Do Q q -40 0 0 -20 80 60 cm /Im1 Do Q");
    defer Document.freeImages(allocator, images);
    try std.testing.expectEqual(@as(usize, 4), images.len);
    try std.testing.expectEqual([4]f64{ 80, 20, 100, 60 }, images[0].rect);
    try std.testing.expectEqual([4]f64{ 170, 80, 210, 200 }, images[1].rect);
    try std.testing.expectEqual([4]f64{ 40, 60, 90, 110 }, images[2].rect);
    try std.testing.expectEqual([4]f64{ 40, 40, 80, 60 }, images[3].rect);
}

fn imagePlacementAllocationProbe(allocator: std.mem.Allocator, doc: *Document) !void {
    const images = try doc.getPageImagesFromContent(0, allocator, allocator, "q 40 0 0 40 20 20 cm /Im1 Do Q q 40 0 0 40 120 20 cm /Im1 Do Q");
    defer Document.freeImages(allocator, images);
    try std.testing.expectEqual(@as(usize, 2), images.len);
}

test "image placement stack ownership is safe across every allocation failure" {
    const allocator = std.testing.allocator;
    const data = try @import("testpdf.zig").generateImagePdf(allocator);
    defer allocator.free(data);
    const doc = try Document.openFromMemory(allocator, data, ErrorConfig.default());
    defer doc.close();
    try std.testing.checkAllAllocationFailures(allocator, imagePlacementAllocationProbe, .{doc});
}

test "page marked content order exposes borrowed structure sequence" {
    const allocator = std.testing.allocator;
    const testpdf = @import("testpdf.zig");
    const pdf_data = try testpdf.generatePartiallyTaggedFormXObjectPdf(allocator);
    defer allocator.free(pdf_data);

    const doc = try Document.openFromMemory(allocator, pdf_data, ErrorConfig.default());
    defer doc.close();

    const order = doc.pageMarkedContentOrder(0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), order.len);
    try std.testing.expectEqual(@as(i32, 0), order[0].mcid);
    try std.testing.expect(doc.pageMarkedContentOrder(1) == null);
}

test "allocated memory path cleanup" {
    // This test exercises the Windows-style allocated memory path
    // to ensure data_is_allocated=true cleanup works correctly.
    // On Windows, openWithConfig uses alignedAlloc instead of mmap.
    const allocator = std.testing.allocator;
    const testpdf = @import("testpdf.zig");

    // Generate test PDF data
    const pdf_data = try testpdf.generateMinimalPdf(allocator, "AllocTest");
    defer allocator.free(pdf_data);

    // Create page-aligned copy (simulates Windows file read path)
    const aligned_data = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), pdf_data.len);
    @memcpy(aligned_data, pdf_data);
    // Note: don't defer free - Document takes ownership

    // Use the allocated memory path (exercises data_is_allocated=true)
    const doc = try Document.openFromMemoryOwnedAlloc(allocator, aligned_data, ErrorConfig.default());
    defer doc.close(); // This must free aligned_data via allocator.free()

    // Verify document parsed correctly
    try std.testing.expectEqual(@as(usize, 1), doc.pageCount());
}

test "owned allocated input is consumed when document allocation fails" {
    const data = try std.testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        std.heap.page_size_min,
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        Document.openFromMemoryOwnedAlloc(failing.allocator(), data, ErrorConfig.default()),
    );
}

fn searchReportOwnershipProbe(allocator: std.mem.Allocator) !void {
    var matches: std.ArrayList(Document.DetailedSearchMatch) = .empty;
    errdefer {
        Document.freeDetailedSearchMatches(allocator, matches.items);
        matches.deinit(allocator);
    }
    var failures: std.ArrayList(Document.SearchPageFailure) = .empty;
    errdefer failures.deinit(allocator);

    const context = try allocator.dupe(u8, "owned context");
    var context_transferred = false;
    errdefer if (!context_transferred) allocator.free(context);
    const glyph_indices = try allocator.dupe(u32, &.{ 2, 4 });
    var glyph_indices_transferred = false;
    errdefer if (!glyph_indices_transferred) allocator.free(glyph_indices);
    try matches.append(allocator, .{
        .page = 0,
        .source_kind = .legacy_structured,
        .normalized_offset = 0,
        .source_start = 0,
        .source_end = 5,
        .context = context,
        .glyph_indices = glyph_indices,
    });
    context_transferred = true;
    glyph_indices_transferred = true;
    try failures.append(allocator, .{
        .page = 0,
        .stage = .full_context_text,
        .error_name = "SyntheticFailure",
    });

    var report = try Document.finishSearchReport(allocator, &matches, &failures, 1);
    defer report.deinit();
}

test "search report ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        searchReportOwnershipProbe,
        .{},
    );
}

fn makeMergeCandidate(
    allocator: std.mem.Allocator,
    source_kind: text_search.SourceKind,
    context: []const u8,
    left_anchor: []const u8,
    normalized_offset: usize,
    glyph_identity: []const u32,
    bbox: ?layout.BBox,
) !Document.SearchCandidate {
    const owned_context = try allocator.dupe(u8, context);
    errdefer allocator.free(owned_context);
    const owned_glyph_identity = try allocator.dupe(u32, glyph_identity);
    errdefer allocator.free(owned_glyph_identity);
    var candidate = Document.SearchCandidate{
        .match = .{
            .page = 0,
            .source_kind = source_kind,
            .normalized_offset = if (Document.sourceOffsetsAreStable(source_kind)) normalized_offset else null,
            .source_start = if (Document.sourceOffsetsAreStable(source_kind)) normalized_offset else null,
            .source_end = if (Document.sourceOffsetsAreStable(source_kind)) normalized_offset + 5 else null,
            .context = owned_context,
            .glyph_indices = owned_glyph_identity,
            .bbox = bbox,
        },
        .normalized_source_hash = @intCast(normalized_offset + @as(usize, @backingInt(source_kind)) + 1),
        .normalized_source_len = 100,
        .normalized_page_offset = normalized_offset,
        .page_position = Document.normalizedPagePosition(normalized_offset, 100),
        .glyph_identity_hash = if (owned_glyph_identity.len > 0)
            std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(owned_glyph_identity))
        else
            null,
    };
    @memcpy(candidate.left_anchor[0..left_anchor.len], left_anchor);
    candidate.left_anchor_len = @intCast(left_anchor.len);
    return candidate;
}

test "search candidate union retains disjoint lane matches and enriches duplicates" {
    const allocator = std.testing.allocator;
    var candidates: [4]std.ArrayList(Document.SearchCandidate) = @splat(.empty);
    defer {
        for (&candidates) |*candidate_list| {
            Document.freeSearchCandidates(allocator, candidate_list.items);
            candidate_list.deinit(allocator);
        }
    }

    try candidates[0].append(allocator, try makeMergeCandidate(
        allocator,
        .legacy_structured,
        "shared occurrence",
        "garbled-before",
        10,
        &.{},
        null,
    ));
    try candidates[0].append(allocator, try makeMergeCandidate(
        allocator,
        .legacy_structured,
        "form-only occurrence",
        "form---before",
        40,
        &.{},
        null,
    ));
    try candidates[1].append(allocator, try makeMergeCandidate(
        allocator,
        .full_context_text,
        "shared occurrence",
        "clean---before",
        11,
        &.{},
        null,
    ));
    var native_shared = try makeMergeCandidate(
        allocator,
        .native_reading,
        "shared occurrence",
        "garbled-before",
        12,
        &.{ 3, 7 },
        .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
    );
    native_shared.match.first_glyph_index = 3;
    native_shared.match.last_glyph_index = 7;
    try candidates[2].append(allocator, native_shared);
    try candidates[2].append(allocator, try makeMergeCandidate(
        allocator,
        .native_reading,
        "native-only occurrence",
        "native-before",
        70,
        &.{ 20, 21 },
        .{ .x0 = 5, .y0 = 6, .x1 = 7, .y1 = 8 },
    ));
    var content_shared = try makeMergeCandidate(
        allocator,
        .native_content,
        "shared occurrence",
        "clean---before",
        13,
        &.{ 3, 7 },
        .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
    );
    content_shared.match.first_glyph_index = 3;
    content_shared.match.last_glyph_index = 7;
    try candidates[3].append(allocator, content_shared);

    var merged: std.ArrayList(Document.DetailedSearchMatch) = .empty;
    defer {
        Document.freeDetailedSearchMatches(allocator, merged.items);
        merged.deinit(allocator);
    }
    try Document.appendUniqueCandidates(allocator, &merged, &candidates, null);

    try std.testing.expectEqual(@as(usize, 3), merged.items.len);
    var found_enriched_shared = false;
    var found_form_only = false;
    var found_native_only = false;
    for (merged.items) |match| {
        if (std.mem.eql(u8, match.context, "shared occurrence")) {
            found_enriched_shared = match.bbox != null and match.source_start == null;
        } else if (std.mem.eql(u8, match.context, "form-only occurrence")) {
            found_form_only = true;
        } else if (std.mem.eql(u8, match.context, "native-only occurrence")) {
            found_native_only = true;
        }
    }
    try std.testing.expect(found_enriched_shared);
    try std.testing.expect(found_form_only);
    try std.testing.expect(found_native_only);
}

test "search candidate union does not merge sparse overlapping glyph ranges" {
    const allocator = std.testing.allocator;
    var candidates: [4]std.ArrayList(Document.SearchCandidate) = @splat(.empty);
    defer {
        for (&candidates) |*candidate_list| {
            Document.freeSearchCandidates(allocator, candidate_list.items);
            candidate_list.deinit(allocator);
        }
    }

    var sparse = try makeMergeCandidate(
        allocator,
        .native_reading,
        "sparse range",
        "left sparse anchor",
        10,
        &.{ 1, 100 },
        .{ .x0 = 1, .y0 = 1, .x1 = 2, .y1 = 2 },
    );
    sparse.match.first_glyph_index = 1;
    sparse.match.last_glyph_index = 100;
    try candidates[2].append(allocator, sparse);

    var middle = try makeMergeCandidate(
        allocator,
        .native_content,
        "middle range",
        "other middle text",
        80,
        &.{50},
        .{ .x0 = 10, .y0 = 10, .x1 = 11, .y1 = 11 },
    );
    middle.match.first_glyph_index = 50;
    middle.match.last_glyph_index = 50;
    try candidates[3].append(allocator, middle);

    var merged: std.ArrayList(Document.DetailedSearchMatch) = .empty;
    defer {
        Document.freeDetailedSearchMatches(allocator, merged.items);
        merged.deinit(allocator);
    }
    try Document.appendUniqueCandidates(allocator, &merged, &candidates, null);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 1, 100 }, merged.items[0].glyph_indices);
    try std.testing.expectEqualSlices(u32, &.{50}, merged.items[1].glyph_indices);
}

test "search candidate union retains short text lanes without identity evidence" {
    const allocator = std.testing.allocator;
    var candidates: [4]std.ArrayList(Document.SearchCandidate) = @splat(.empty);
    defer {
        for (&candidates) |*candidate_list| {
            Document.freeSearchCandidates(allocator, candidate_list.items);
            candidate_list.deinit(allocator);
        }
    }
    try candidates[0].append(allocator, try makeMergeCandidate(
        allocator,
        .legacy_structured,
        "Title",
        "",
        0,
        &.{},
        null,
    ));
    try candidates[1].append(allocator, try makeMergeCandidate(
        allocator,
        .full_context_text,
        "Title with divergent surrounding extraction",
        "different",
        0,
        &.{},
        null,
    ));

    var merged: std.ArrayList(Document.DetailedSearchMatch) = .empty;
    defer {
        Document.freeDetailedSearchMatches(allocator, merged.items);
        merged.deinit(allocator);
    }
    try Document.appendUniqueCandidates(allocator, &merged, &candidates, null);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
}

test "search result cap is applied after deterministic page ordering" {
    const allocator = std.testing.allocator;
    var candidates: [4]std.ArrayList(Document.SearchCandidate) = @splat(.empty);
    defer {
        for (&candidates) |*candidate_list| {
            Document.freeSearchCandidates(allocator, candidate_list.items);
            candidate_list.deinit(allocator);
        }
    }
    try candidates[0].append(allocator, try makeMergeCandidate(
        allocator,
        .legacy_structured,
        "late occurrence",
        "late context",
        80,
        &.{},
        null,
    ));
    try candidates[1].append(allocator, try makeMergeCandidate(
        allocator,
        .full_context_text,
        "early occurrence",
        "early context",
        10,
        &.{},
        null,
    ));

    var merged: std.ArrayList(Document.DetailedSearchMatch) = .empty;
    defer {
        Document.freeDetailedSearchMatches(allocator, merged.items);
        merged.deinit(allocator);
    }
    try Document.appendUniqueCandidates(allocator, &merged, &candidates, 1);
    try std.testing.expectEqual(@as(usize, 1), merged.items.len);
    try std.testing.expectEqualStrings("early occurrence", merged.items[0].context);
}

fn searchCandidateUnionAllocationProbe(allocator: std.mem.Allocator) !void {
    var candidates: [4]std.ArrayList(Document.SearchCandidate) = @splat(.empty);
    defer {
        for (&candidates) |*candidate_list| {
            Document.freeSearchCandidates(allocator, candidate_list.items);
            candidate_list.deinit(allocator);
        }
    }
    try candidates[0].ensureUnusedCapacity(allocator, 1);
    const text_candidate = try makeMergeCandidate(
        allocator,
        .legacy_structured,
        "text candidate",
        "shared anchor",
        10,
        &.{},
        null,
    );
    candidates[0].appendAssumeCapacity(text_candidate);
    try candidates[2].ensureUnusedCapacity(allocator, 1);
    const glyph_candidate = try makeMergeCandidate(
        allocator,
        .native_reading,
        "glyph candidate",
        "shared anchor",
        10,
        &.{ 3, 4, 5 },
        .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 },
    );
    candidates[2].appendAssumeCapacity(glyph_candidate);

    var merged: std.ArrayList(Document.DetailedSearchMatch) = .empty;
    defer {
        Document.freeDetailedSearchMatches(allocator, merged.items);
        merged.deinit(allocator);
    }
    try Document.appendUniqueCandidates(allocator, &merged, &candidates, null);
}

test "search candidate union ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        searchCandidateUnionAllocationProbe,
        .{},
    );
}

fn pageGeometryDocumentFixture(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var writer = runtime.arrayListWriter(&bytes, allocator);
    const objects = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [10 20 110 220] /CropBox [25 40 100 200] /Rotate 90 /UserUnit 3 >>",
        "<< /Type /Page /Parent 2 0 R /UserUnit 5 0 R /Rotate 0 >>",
        "<< /Type /Page /Parent 2 0 R >>",
        "2",
    };
    var offsets: [objects.len]usize = undefined;
    try writer.writeAll("%PDF-1.7\n");
    for (objects, 0..) |object, index| {
        offsets[index] = bytes.items.len;
        try writer.print("{d} 0 obj\n{s}\nendobj\n", .{ index + 1, object });
    }
    const xref_offset = bytes.items.len;
    try writer.print("xref\n0 {d}\n0000000000 65535 f \n", .{objects.len + 1});
    for (offsets) |offset| try writer.print("{d:0>10} 00000 n \n", .{offset});
    try writer.print("trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ objects.len + 1, xref_offset });
    return bytes.toOwnedSlice(allocator);
}

test "document page geometry preserves raw origins inherited boxes and leaf UserUnit" {
    const allocator = std.testing.allocator;
    const bytes = try pageGeometryDocumentFixture(allocator);
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    try std.testing.expectEqual(@as(usize, 2), doc.pageCount());
    const first = doc.getPageGeometry(0).?;
    const second = doc.getPageGeometry(1).?;
    try std.testing.expectEqual(@as(f64, 2), first.user_unit);
    try std.testing.expectEqual(@as(f64, 1), second.user_unit);
    try std.testing.expectEqual(page_geometry.QuarterTurn.clockwise_90, second.rotation);
    try std.testing.expectEqual(layout.BBox{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 220 }, first.media_box);
    try std.testing.expectEqual(layout.BBox{ .x0 = 25, .y0 = 40, .x1 = 100, .y1 = 200 }, first.crop_box);
    try std.testing.expectEqual(@as(f64, 100), doc.getPageInfo(0).?.width);
    try std.testing.expectEqual(@as(f64, 200), doc.getPageInfo(0).?.height);
    try std.testing.expectEqual(@as(f64, 200), first.media.width_points);
    try std.testing.expectEqual(@as(f64, 400), first.media.height_points);
    try std.testing.expect(doc.getPageGeometry(2) == null);
}

test "document page geometry literal quarter transforms and unsupported geometry" {
    const allocator = std.testing.allocator;
    const bytes = try pageGeometryDocumentFixture(allocator);
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    const point: page_geometry.Point = .{ .x = 40, .y = 50 };
    const expected_media = [_]page_geometry.Point{ .{ .x = 60, .y = 340 }, .{ .x = 60, .y = 60 }, .{ .x = 140, .y = 60 }, .{ .x = 340, .y = 140 } };
    const expected_crop = [_]page_geometry.Point{ .{ .x = 30, .y = 300 }, .{ .x = 20, .y = 30 }, .{ .x = 120, .y = 20 }, .{ .x = 300, .y = 120 } };
    for ([_]i32{ 0, 90, 180, 270 }, 0..) |rotation, index| {
        doc.pages.items[0].rotation = rotation;
        const model = doc.getPageGeometry(0).?;
        try std.testing.expectEqual(expected_media[index], try page_geometry.mapPoint(model.pdfToDisplay(.media), point));
        try std.testing.expectEqual(expected_crop[index], try page_geometry.mapPoint(model.pdfToDisplay(.crop), point));
        try std.testing.expectEqual(point, try page_geometry.mapPoint(model.displayToPdf(.crop), expected_crop[index]));
    }
    doc.pages.items[0].rotation = 45;
    try std.testing.expect(doc.getPageGeometry(0) == null);
    doc.pages.items[0].rotation = 0;
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64), 75001 }) |unit| {
        doc.pages.items[0].user_unit = unit;
        try std.testing.expect(doc.getPageGeometry(0) == null);
    }
    doc.pages.items[0].user_unit = 1;
    doc.pages.items[0].crop_box = .{ 300, 400, 400, 500 };
    try std.testing.expect(doc.getPageGeometry(0) == null);
}

test "formula crop geometry is padded clamped and top-left mapped" {
    const geometry = Document.formulaCropGeometry(
        .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        .{ .x0 = 100, .y0 = 200, .x1 = 200, .y1 = 250 },
        4,
        144,
    ).?;
    try std.testing.expectEqual(@as(u32, 192), geometry.x);
    try std.testing.expectEqual(@as(u32, 1076), geometry.y);
    try std.testing.expectEqual(@as(u32, 216), geometry.width);
    try std.testing.expectEqual(@as(u32, 116), geometry.height);
    try std.testing.expectEqual(@as(f64, 96), geometry.pdf_bbox.x0);
    try std.testing.expectEqual(@as(f64, 254), geometry.pdf_bbox.y1);

    const clamped = Document.formulaCropGeometry(
        .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 },
        .{ .x0 = -10, .y0 = 90, .x1 = 12, .y1 = 110 },
        4,
        72,
    ).?;
    try std.testing.expectEqual(@as(u32, 0), clamped.x);
    try std.testing.expectEqual(@as(u32, 0), clamped.y);
    try std.testing.expectEqual(@as(u32, 16), clamped.width);
    try std.testing.expectEqual(@as(u32, 14), clamped.height);
}

fn regionalOcrAllocationProbe(allocator: std.mem.Allocator, doc: *Document, bbox: layout.BBox) !void {
    var outcome = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = "./definitely-missing-crop-rasterizer" });
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(ocr.AttemptStatus.unavailable, outcome.status);
}

test "regional OCR preflight preserves unsupported and bounded outcomes" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());
    const bytes = try @import("testpdf.zig").generateMinimalPdf(allocator, "OCR bounds");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    const bbox = layout.BBox{ .x0 = 10, .y0 = 10, .x1 = 20, .y1 = 30 };
    var memory = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{});
    defer memory.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_requires_file, memory.diagnostic_code.?);
    doc.source_path = try allocator.dupe(u8, "unused.pdf");
    doc.pages.items[0].rotation = 45;
    var rotated = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{});
    defer rotated.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_rotation_unsupported, rotated.diagnostic_code.?);
    doc.pages.items[0].rotation = 0;
    var pixels = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .max_image_pixels = 1 });
    defer pixels.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_pixel_limit, pixels.diagnostic_code.?);
    var image_bytes = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .max_image_bytes = 1 });
    defer image_bytes.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_image_byte_limit, image_bytes.diagnostic_code.?);
    var invalid = try doc.rasterizeOcrRegionDetailed(allocator, 0, .{ .x0 = 20, .y0 = 30, .x1 = 10, .y1 = 10 }, .{});
    defer invalid.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.invalid_crop_geometry, invalid.diagnostic_code.?);
    var unavailable = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = "./definitely-missing-crop-rasterizer" });
    defer unavailable.deinit(allocator);
    try std.testing.expectEqual(ocr.AttemptStatus.unavailable, unavailable.status);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_unavailable, unavailable.diagnostic_code.?);
    try std.testing.checkAllAllocationFailures(allocator, regionalOcrAllocationProbe, .{ doc, bbox });
}

test "regional OCR fake rasterizer validates crop identity and cleans rejected images" {
    if (builtin.target.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());
    const bytes = try @import("testpdf.zig").generateMinimalPdf(allocator, "OCR fake crop");
    defer allocator.free(bytes);
    const doc = try Document.openFromMemory(allocator, bytes, ErrorConfig.default());
    defer doc.close();
    doc.source_path = try allocator.dupe(u8, "unused.pdf");
    const script_path = try std.fmt.allocPrint(allocator, ".pdf-parser-crop-raster-{x}.sh", .{runtime.nanoTimestamp()});
    defer allocator.free(script_path);
    defer runtime.deleteFileCwd(script_path);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{script_path});
    defer allocator.free(log_path);
    defer runtime.deleteFileCwd(log_path);
    const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nlast=''\nfor arg do last=\"$arg\"; done\nprintf '%s' \"$last.png\" > '{s}'\nprintf '\\211PNG\\r\\n\\032\\n\\000\\000\\000\\rIHDR\\000\\000\\000\\012\\000\\000\\000\\024' > \"$last.png\"\n", .{log_path});
    defer allocator.free(script);
    const file = try runtime.createFileCwd(script_path);
    try runtime.writeAllFile(file, script);
    runtime.closeFile(file);
    try std.testing.expectEqual(@as(u8, 0), try runtime.runIgnored(&.{ "chmod", "+x", script_path }));
    const executable = try std.fmt.allocPrint(allocator, "./{s}", .{script_path});
    defer allocator.free(executable);
    const bbox = layout.BBox{ .x0 = 10, .y0 = 10, .x1 = 20, .y1 = 30 };
    var success = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = executable, .dpi = 72, .crop_padding_points = 0 });
    defer success.deinit(allocator);
    try std.testing.expectEqual(ocr.AttemptStatus.completed, success.status);
    const input = success.input.?;
    defer allocator.free(@constCast(input.image_path));
    runtime.deleteFileCwd(input.image_path);
    try std.testing.expectEqual(@as(usize, 24), input.image_byte_length.?);
    try std.testing.expect(input.image_sha256 != null);
    {
        const original_media_box = doc.pages.items[0].media_box;
        defer doc.pages.items[0].media_box = original_media_box;
        doc.pages.items[0].media_box = .{ 0, 0, 9.8, 19.8 };
        const fractional_page = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 9.8, .y1 = 19.8 };
        var whole = try doc.rasterizePageForOcrDetailed(allocator, 0, .{ .rasterizer_executable = executable, .dpi = 72 });
        defer whole.deinit(allocator);
        try std.testing.expectEqual(ocr.AttemptStatus.completed, whole.status);
        const whole_input = whole.input.?;
        defer allocator.free(@constCast(whole_input.image_path));
        defer runtime.deleteFileCwd(whole_input.image_path);
        try std.testing.expectEqual(fractional_page, whole_input.pdf_bbox);
        try std.testing.expectEqual(@as(u32, 10), whole_input.pixel_width);
        try std.testing.expectEqual(@as(u32, 20), whole_input.pixel_height);

        var fractional_crop = try doc.rasterizeOcrRegionDetailed(allocator, 0, fractional_page, .{ .rasterizer_executable = executable, .dpi = 72, .crop_padding_points = 0 });
        defer fractional_crop.deinit(allocator);
        try std.testing.expectEqual(ocr.AttemptStatus.completed, fractional_crop.status);
        const crop_input = fractional_crop.input.?;
        defer allocator.free(@constCast(crop_input.image_path));
        defer runtime.deleteFileCwd(crop_input.image_path);
        try std.testing.expectEqual(@as(f64, 10), crop_input.pdf_bbox.x1);
        try std.testing.expectApproxEqAbs(@as(f64, -0.2), crop_input.pdf_bbox.y0, 0.000001);
    }
    var oversized = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = executable, .dpi = 72, .crop_padding_points = 0, .max_image_bytes = 23 });
    defer oversized.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_image_byte_limit, oversized.diagnostic_code.?);
    // A valid preflight with a mismatched raster size fails after the child
    // exits, and the generated file is deleted before returning the outcome.
    var wrong_size = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = executable, .dpi = 144, .crop_padding_points = 0 });
    defer wrong_size.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.invalid_raster_image, wrong_size.diagnostic_code.?);
    const rejected_path = try runtime.readFileAllocAlignedCwd(allocator, log_path, .fromByteUnits(1));
    defer allocator.free(rejected_path);
    try std.testing.expectError(error.FileNotFound, runtime.fileSizeCwd(rejected_path));

    const larger_script = try std.fmt.allocPrint(allocator, "{s}printf X >> \"$last.png\"\n", .{script});
    defer allocator.free(larger_script);
    const larger_file = try runtime.createFileCwd(script_path);
    try runtime.writeAllFile(larger_file, larger_script);
    runtime.closeFile(larger_file);
    var bytes_limit = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = executable, .dpi = 72, .crop_padding_points = 0, .max_image_bytes = 24 });
    defer bytes_limit.deinit(allocator);
    try std.testing.expectEqual(ocr.DiagnosticCode.rasterizer_image_byte_limit, bytes_limit.diagnostic_code.?);
    const large_path = try runtime.readFileAllocAlignedCwd(allocator, log_path, .fromByteUnits(1));
    defer allocator.free(large_path);
    try std.testing.expectError(error.FileNotFound, runtime.fileSizeCwd(large_path));

    const timeout_script = try std.fmt.allocPrint(allocator, "{s}while :; do :; done\n", .{script});
    defer allocator.free(timeout_script);
    const timeout_file = try runtime.createFileCwd(script_path);
    try runtime.writeAllFile(timeout_file, timeout_script);
    runtime.closeFile(timeout_file);
    var timed_out = try doc.rasterizeOcrRegionDetailed(allocator, 0, bbox, .{ .rasterizer_executable = executable, .dpi = 72, .crop_padding_points = 0, .timeout_ms = 30 });
    defer timed_out.deinit(allocator);
    try std.testing.expectEqual(ocr.AttemptStatus.timeout, timed_out.status);
    const timeout_path = try runtime.readFileAllocAlignedCwd(allocator, log_path, .fromByteUnits(1));
    defer allocator.free(timeout_path);
    try std.testing.expectError(error.FileNotFound, runtime.fileSizeCwd(timeout_path));
}
