/* SPDX-License-Identifier: GPL-3.0-only */
/* MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *symbol(void *lib, const char *name)
{
    void *p = dlsym(lib, name);
    if (!p) { fprintf(stderr, "%s\n", dlerror()); exit(1); }
    return p;
}
static void *library(const char *root, const char *relative)
{
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/%s", root, relative) >= sizeof(path)) exit(1);
    void *p = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!p) { fprintf(stderr, "%s\n", dlerror()); exit(1); }
    return p;
}
int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    void *tls = library(argv[1], "lib/libgnutls.30.dylib");
    int (*tls_init)(void) = symbol(tls, "gnutls_global_init");
    void (*tls_done)(void) = symbol(tls, "gnutls_global_deinit");
    if (tls_init()) return 1;
    tls_done();
    void *ft = library(argv[1], "lib/libfreetype.6.dylib"), *ft_instance = NULL;
    int (*ft_init)(void **) = symbol(ft, "FT_Init_FreeType");
    int (*ft_done)(void *) = symbol(ft, "FT_Done_FreeType");
    if (ft_init(&ft_instance) || ft_done(ft_instance)) return 1;
    void *gst = library(argv[1], "lib/GStreamer.framework/Versions/1.0/lib/libgstreamer-1.0.0.dylib");
    int (*gst_init)(int *, char ***, void **) = symbol(gst, "gst_init_check");
    void (*gst_done)(void) = symbol(gst, "gst_deinit");
    if (!gst_init(NULL, NULL, NULL)) return 1;
    gst_done();
    void *av = library(argv[1], "lib/GStreamer.framework/Versions/1.0/lib/libavcodec.61.dylib");
    const void *(*decoder)(const char *) = symbol(av, "avcodec_find_decoder_by_name");
    if (!decoder("h264")) return 1;
    puts("TLS, FreeType, GStreamer initialization and H264 decoder lookup passed");
    return 0;
}
