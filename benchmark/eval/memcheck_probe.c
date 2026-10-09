/* Intentionally faulty qualification programs. Never part of ordinary tests. */
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdio.h>

static volatile unsigned char sink;

/* Keep the lost pointer out of main's live stack frame. Subsequent allocation
 * calls replace caller-saved register copies before Memcheck's exit scan. */
__attribute__((noinline)) static void lose_block(void) {
    volatile unsigned char *lost = malloc(16);
    if (!lost) exit(2);
    lost[0] = 42;
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "library-clean") == 0) {
        void *handle = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
        if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 2; }
        return dlclose(handle) == 0 ? 0 : 2;
    }
    if (argc != 2) return 2;
    if (strcmp(argv[1], "leak") == 0) {
        lose_block();
        volatile unsigned char *control = malloc(16);
        if (!control) return 2;
        control[0] = 1;
        sink = control[0];
        free((void *)control);
        return 0;
    }
    volatile unsigned char *p = malloc(16);
    if (!p) return 2;
    p[0] = 42;
    if (strcmp(argv[1], "clean") == 0) {
        sink = p[0];
        free((void *)p);
    } else if (strcmp(argv[1], "invalid-access") == 0) {
        p[16] = 1;
        free((void *)p);
    } else if (strcmp(argv[1], "use-after-free") == 0) {
        free((void *)p);
        sink = p[0];
    } else {
        free((void *)p);
        return 2;
    }
    return 0;
}
