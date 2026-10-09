/* Public ABI lifecycle smoke. Checks remain active even with NDEBUG. */
#include "pdf_parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Legacy declarations match python/zpdf/_cdef.h. */
typedef struct ZpdfDocument ZpdfDocument;
typedef struct {
    double x0, y0, x1, y1;
    const char *text;
    size_t text_len;
    double font_size;
    uint32_t page_index;
    uint8_t source_kind;
    float confidence;
    int32_t block_id, line_id, mcid;
} CTextSpan;
ZpdfDocument *zpdf_open(const char *path);
ZpdfDocument *zpdf_open_memory(const uint8_t *data, size_t len);
ZpdfDocument *zpdf_open_memory_unsafe(const uint8_t *data, size_t len);
void zpdf_close(ZpdfDocument *doc);
int zpdf_page_count(ZpdfDocument *doc);
uint8_t *zpdf_extract_page(ZpdfDocument *doc, int page, size_t *len);
uint8_t *zpdf_extract_all(ZpdfDocument *doc, size_t *len);
void zpdf_free_buffer(uint8_t *ptr, size_t len);
CTextSpan *zpdf_extract_bounds(ZpdfDocument *doc, int page, size_t *count);
void zpdf_free_bounds(CTextSpan *ptr, size_t count);

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "ABI check failed at line %d: %s\n", __LINE__, #expr); return 1; } } while (0)

static int contains(const uint8_t *data, size_t len, const char *needle) {
    size_t n = strlen(needle);
    for (size_t i = 0; i + n <= len; i++)
        if (memcmp(data + i, needle, n) == 0) return 1;
    return 0;
}

static int exercise_document(ZpdfDocument *doc) {
    CHECK(doc != NULL);
    CHECK(zpdf_page_count(doc) > 0);
    size_t len = 0;
    uint8_t *text = zpdf_extract_page(doc, 0, &len);
    CHECK(text != NULL && contains(text, len, "Clean born digital"));
    zpdf_free_buffer(text, len);
    text = zpdf_extract_all(doc, &len);
    CHECK(text != NULL && contains(text, len, "Clean born digital"));
    pdf_parser_free_buffer(text, len);
    size_t count = 0;
    CTextSpan *spans = zpdf_extract_bounds(doc, 0, &count);
    CHECK(spans != NULL && count > 0);
    int nonempty = 0;
    for (size_t i = 0; i < count; i++) {
        CHECK(spans[i].x1 >= spans[i].x0 && spans[i].y1 >= spans[i].y0);
        if (spans[i].text_len) { CHECK(spans[i].text != NULL); nonempty = 1; }
    }
    CHECK(nonempty);
    zpdf_free_bounds(spans, count);
    len = 999;
    CHECK(zpdf_extract_page(doc, -1, &len) == NULL && len == 0);
    CHECK(zpdf_last_error() == ZPDF_ERROR_PAGE_NOT_FOUND);
    CHECK(zpdf_extract_page(doc, zpdf_page_count(doc), &len) == NULL && len == 0);
    zpdf_close(doc);
    return 0;
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    CHECK(pdf_parser_abi_version() == PDF_PARSER_ABI_VERSION);
    FILE *f = fopen(argv[1], "rb");
    CHECK(f != NULL && fseek(f, 0, SEEK_END) == 0);
    long size = ftell(f);
    CHECK(size > 8 && fseek(f, 0, SEEK_SET) == 0);
    uint8_t *data = malloc((size_t)size);
    CHECK(data != NULL && fread(data, 1, (size_t)size, f) == (size_t)size);
    CHECK(fclose(f) == 0);
    for (int i = 0; i < 3; i++) {
        CHECK(exercise_document(zpdf_open(argv[1])) == 0);
        CHECK(exercise_document(zpdf_open_memory(data, (size_t)size)) == 0);
        CHECK(exercise_document(zpdf_open_memory_unsafe(data, (size_t)size)) == 0);
        PdfParserAdaptiveOptions opts = {0};
        opts.abi_version = PDF_PARSER_ABI_VERSION;
        opts.input_path = argv[1];
        opts.source_id = "memcheck-abi";
        opts.page_start = opts.page_end = -1;
        opts.permissive = 1;
        for (int format = PDF_PARSER_FORMAT_ARTIFACT_JSONL; format <= PDF_PARSER_FORMAT_STREAM_JSONL; format++) {
            opts.format = format;
            PdfParserAdaptiveResult result = {0};
            CHECK(pdf_parser_extract_adaptive_file(&opts, &result) == PDF_PARSER_STATUS_OK);
            CHECK(result.output != NULL && contains(result.output, result.output_len, "document_manifest"));
            CHECK(contains(result.output, result.output_len, "Clean born digital"));
            /* Reusing a result exercises clear-before-replace as well as explicit clear. */
            CHECK(pdf_parser_extract_adaptive_memory(&opts, data, (size_t)size, &result) == PDF_PARSER_STATUS_OK);
            CHECK(contains(result.output, result.output_len, "Clean born digital"));
            if (format == PDF_PARSER_FORMAT_STREAM_JSONL)
                CHECK(contains(result.output, result.output_len, "document_finished"));
            pdf_parser_result_clear(&result);
            CHECK(result.output == NULL && result.output_len == 0 && result.error_message == NULL);
            pdf_parser_result_clear(&result);
        }
        PdfParserAdaptiveResult result = {0};
        CHECK(pdf_parser_extract_adaptive_file(NULL, &result) == PDF_PARSER_STATUS_INVALID_ARGUMENT);
        CHECK(result.error_message != NULL && result.error_len > 0);
        CHECK(pdf_parser_extract_adaptive_memory(&opts, NULL, 0, &result) == PDF_PARSER_STATUS_INVALID_ARGUMENT);
        opts.abi_version = 0;
        CHECK(pdf_parser_extract_adaptive_file(&opts, &result) == PDF_PARSER_STATUS_INVALID_ARGUMENT);
        opts.abi_version = PDF_PARSER_ABI_VERSION;
        CHECK(pdf_parser_extract_adaptive_file(&opts, NULL) == PDF_PARSER_STATUS_INVALID_ARGUMENT);
        const uint8_t malformed[] = "not a PDF";
        const uint8_t truncated[] = "%PDF-1.7\n";
        /* The legacy boundary is deliberately permissive: recover zero-page docs. */
        ZpdfDocument *bad_doc = zpdf_open_memory(malformed, sizeof(malformed) - 1);
        CHECK(bad_doc != NULL && zpdf_page_count(bad_doc) == 0);
        zpdf_close(bad_doc);
        bad_doc = zpdf_open_memory(truncated, sizeof(truncated) - 1);
        CHECK(bad_doc != NULL && zpdf_page_count(bad_doc) == 0);
        zpdf_close(bad_doc);
        opts.strict = 1;
        opts.permissive = 0;
        CHECK(pdf_parser_extract_adaptive_memory(&opts, malformed, sizeof(malformed) - 1, &result) == PDF_PARSER_STATUS_OPEN_ERROR);
        CHECK(pdf_parser_extract_adaptive_memory(&opts, truncated, sizeof(truncated) - 1, &result) == PDF_PARSER_STATUS_OPEN_ERROR);
        pdf_parser_result_clear(&result);
    }
    size_t len = 999;
    CHECK(zpdf_page_count(NULL) == -1);
    CHECK(zpdf_extract_page(NULL, 0, &len) == NULL && len == 0);
    CHECK(zpdf_last_error() == ZPDF_ERROR_INVALID_HANDLE);
    zpdf_close(NULL);
    pdf_parser_result_clear(NULL);
    free(data);
    puts("ABI lifecycle passed: 9 document cycles, 12 adaptive calls, invalid arguments and malformed/truncated inputs");
    return 0;
}
