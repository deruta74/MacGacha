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
