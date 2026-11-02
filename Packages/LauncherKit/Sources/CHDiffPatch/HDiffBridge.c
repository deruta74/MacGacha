// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
#include "include/CHDiffPatch.h"
#include "vendor/libHDiffPatch/HPatch/patch_private.h"
#include <stdlib.h>
#include <string.h>

#define MG_IO_SIZE (64u << 10)
#define MG_CACHE_SIZE (6u * (16u << 10))

typedef struct { const MGHDiffCallbacks* callbacks; uint64_t written; } MGState;
typedef struct { MGState* state; MGHDiffRead read; } MGInput;

static int mg_cancelled(MGState* state) {
    return state->callbacks->cancelled(state->callbacks->context);
}
static hpatch_BOOL mg_read(const hpatch_TStreamInput* stream, hpatch_StreamPos_t position,
                           unsigned char* output, unsigned char* end) {
    MGInput* input = (MGInput*)stream->streamImport;
    size_t length = (size_t)(end - output);
    if (position > stream->streamSize || length > stream->streamSize - position) return hpatch_FALSE;
    while (length) {
        size_t count = length < MG_IO_SIZE ? length : MG_IO_SIZE;
        if (mg_cancelled(input->state) || !input->read(input->state->callbacks->context, position, output, count)) return hpatch_FALSE;
        position += count; output += count; length -= count;
    }
    return hpatch_TRUE;
}
static hpatch_BOOL mg_write(const hpatch_TStreamOutput* stream, hpatch_StreamPos_t position,
                            const unsigned char* bytes, const unsigned char* end) {
    MGState* state = (MGState*)stream->streamImport;
    size_t length = (size_t)(end - bytes);
    if (position != state->written || position > stream->streamSize || length > stream->streamSize - position) return hpatch_FALSE;
    while (length) {
        size_t count = length < MG_IO_SIZE ? length : MG_IO_SIZE;
        if (mg_cancelled(state) || !state->callbacks->write_new(state->callbacks->context, position, bytes, count)) return hpatch_FALSE;
        position += count; state->written += count; bytes += count; length -= count;
    }
    return hpatch_TRUE;
}

// Validate section arithmetic before upstream initializes clips (whose contracts
// use assertions). Each section must be wholly inside this one patch slice.
static int mg_sections(const _THDiffzHead* head, uint64_t patch_size) {
    const uint64_t decoded[4] = {head->cover_buf_size, head->rle_ctrlBuf_size, head->rle_codeBuf_size, head->newDataDiff_size};
    const uint64_t compressed[4] = {head->compress_cover_buf_size, head->compress_rle_ctrlBuf_size,
                                  head->compress_rle_codeBuf_size, head->compress_newDataDiff_size};
    uint64_t position = head->headEndPos;
    if (position > patch_size || head->coverCount > head->cover_buf_size / 3) return 0;
    for (int i = 0; i < 4; ++i) {
        uint64_t length = compressed[i] ? compressed[i] : decoded[i];
        if (decoded[i] > INT64_MAX || length > patch_size - position) return 0;
        position += length;
    }
    return position == patch_size;
}

MGHDiffResult mg_hdiff_apply(const MGHDiffCallbacks* callbacks, uint64_t old_size,
                            uint64_t patch_size, uint64_t new_size, MGHDiffInfo* info) {
    MGState state = {callbacks, 0};
    MGInput old_input = {&state, callbacks->read_old}, patch_input = {&state, callbacks->read_patch};
    hpatch_TStreamInput old = {&old_input, old_size, mg_read, 0}, patch = {&patch_input, patch_size, mg_read, 0};
    hpatch_TStreamOutput output = {&state, new_size, 0, mg_write};
    hpatch_compressedDiffInfo header;
    _THDiffzHead head;
    unsigned char* cache;
    MGHDiffResult result;
    if (mg_cancelled(&state)) return mg_hdiff_cancelled;
    if (!read_diffz_head(&header, &head, &patch)) return mg_cancelled(&state) ? mg_hdiff_cancelled : mg_hdiff_malformed;
    if (header.newDataSize > INT64_MAX || header.oldDataSize > INT64_MAX) return mg_hdiff_malformed;
    info->old_size = header.oldDataSize; info->new_size = header.newDataSize;
    if (header.compressType[0]) return mg_hdiff_unsupported_compressor;
    if (header.oldDataSize != old_size) return mg_hdiff_old_size;
    if (header.newDataSize != new_size) return mg_hdiff_new_size;
    if (header.compressedCount || !mg_sections(&head, patch_size)) return mg_hdiff_malformed;
    cache = (unsigned char*)malloc(MG_CACHE_SIZE);
    if (!cache) return mg_hdiff_memory;
    result = patch_decompress_with_cache(&output, &old, &patch, 0, cache, cache + MG_CACHE_SIZE)
             && state.written == new_size ? mg_hdiff_ok : mg_hdiff_malformed;
    free(cache);
    return mg_cancelled(&state) ? mg_hdiff_cancelled : result;
}
