// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
#ifndef MACGACHA_C_HDIFF_PATCH_H
#define MACGACHA_C_HDIFF_PATCH_H
// Keep Clang's Swift importer on the same subset as the C compilation.
#define _IS_USED_MULTITHREAD 0
#define _HPATCH_IS_USED_MULTITHREAD 0
#define _IS_NEED_CACHE_OLD_ALL 0
#define _IS_NEED_CACHE_OLD_BY_COVERS 0
#include "../vendor/libHDiffPatch/HPatch/patch.h"
#endif

#ifndef MACGACHA_HDIFF_BRIDGE_H
#define MACGACHA_HDIFF_BRIDGE_H
#include <stddef.h>
#include <stdint.h>

typedef int (*MGHDiffRead)(void*, uint64_t, unsigned char*, size_t);
typedef int (*MGHDiffWrite)(void*, uint64_t, const unsigned char*, size_t);
typedef int (*MGHDiffCancelled)(void*);
typedef struct {
    void* context;
    MGHDiffRead read_old;
    MGHDiffRead read_patch;
    MGHDiffWrite write_new;
    MGHDiffCancelled cancelled;
} MGHDiffCallbacks;
typedef struct { uint64_t old_size, new_size; } MGHDiffInfo;
typedef enum {
    mg_hdiff_ok, mg_hdiff_malformed, mg_hdiff_unsupported_compressor,
    mg_hdiff_old_size, mg_hdiff_new_size, mg_hdiff_cancelled, mg_hdiff_memory
} MGHDiffResult;
MGHDiffResult mg_hdiff_apply(const MGHDiffCallbacks* callbacks, uint64_t old_size,
                            uint64_t patch_size, uint64_t new_size, MGHDiffInfo* info);
#endif
