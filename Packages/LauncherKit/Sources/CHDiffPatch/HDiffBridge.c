// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
#include "include/CHDiffPatch.h"
#include "vendor/libHDiffPatch/HPatch/patch_private.h"
#include <stdlib.h>
#include <string.h>
#define ZSTD_STATIC_LINKING_ONLY
#include "CZstd.h"

#define MG_IO_SIZE (64u << 10)
#define MG_CACHE_STEP_MAX (16u << 10)

#define MG_MEMORY_LIMIT (64u << 20)
#define MG_ZSTD_WINDOW_LOG 23

typedef struct {
    const MGHDiffCallbacks* callbacks;
    uint64_t written;
    size_t allocated;
    int memory_failed;
    size_t read_step;
} MGState;

// Includes the allocation headers, stream input buffers, patch cache and all
// Zstandard contexts/windows. No size from the patch bypasses this budget.
typedef union { max_align_t alignment; size_t size; } MGAllocation;
static void* mg_allocate(void* opaque, size_t size) {
    MGState* state = (MGState*)opaque;
    size_t remaining = MG_MEMORY_LIMIT - state->allocated;
    MGAllocation* allocation;
    if (remaining < sizeof(MGAllocation) || size > remaining - sizeof(MGAllocation)) {
        state->memory_failed = 1; return 0;
    }
    allocation = (MGAllocation*)malloc(sizeof(MGAllocation) + size);
    if (!allocation) { state->memory_failed = 1; return 0; }
    allocation->size = sizeof(MGAllocation) + size;
    state->allocated += allocation->size;
    return allocation + 1;
}
static void mg_free(void* opaque, void* bytes) {
    if (bytes) {
        MGAllocation* allocation = (MGAllocation*)bytes - 1;
        ((MGState*)opaque)->allocated -= allocation->size;
        free(allocation);
    }
}
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
        size_t count = length < input->state->read_step ? length : input->state->read_step;
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

typedef struct { hpatch_TDecompress base; MGState* state; } MGPlugin;
typedef struct {
    MGState* state;
    const hpatch_TStreamInput* source;
    uint64_t position, end, expected, produced;
    ZSTD_DStream* decoder;
    size_t input_size, input_position;
    int ended, failed;
    unsigned char input[MG_IO_SIZE];
} MGZstd;

static int mg_zstd_error(MGZstd* decoder, size_t result) {
    if (!ZSTD_isError(result)) return 0;
    ZSTD_ErrorCode code = ZSTD_getErrorCode(result);
    if (code == ZSTD_error_memory_allocation || code == ZSTD_error_frameParameter_windowTooLarge)
        decoder->state->memory_failed = 1;
    decoder->failed = 1;
    return 1;
}
static int mg_zstd_fill(MGZstd* decoder) {
    uint64_t remaining;
    size_t count;
    if (mg_cancelled(decoder->state)) { decoder->failed = 1; return 0; }
    if (decoder->input_position < decoder->input_size) return 1;
    remaining = decoder->end - decoder->position;
    if (!remaining) return 1; // The decoder can still have buffered output or an end marker.
    count = remaining < decoder->state->read_step ? (size_t)remaining : decoder->state->read_step;
    if (!decoder->source->read(decoder->source, decoder->position, decoder->input, decoder->input + count)) {
        decoder->failed = 1; return 0;
    }
    decoder->position += count;
    decoder->input_position = 0; decoder->input_size = count;
    return 1;
}
static int mg_zstd_step(MGZstd* decoder, ZSTD_outBuffer* output) {
    size_t old_output, result;
    ZSTD_inBuffer input;
    if (!mg_zstd_fill(decoder)) return 0;
    input.src = decoder->input; input.size = decoder->input_size; input.pos = decoder->input_position;
    old_output = output->pos;
    result = ZSTD_decompressStream(decoder->decoder, output, &input);
    if (mg_zstd_error(decoder, result)) return 0;
    if (input.pos == decoder->input_position && output->pos == old_output && result != 0) {
        decoder->failed = 1; return 0;
    }
    decoder->input_position = input.pos;
    if (result == 0) decoder->ended = 1;
    return 1;
}
static int mg_zstd_finish(MGZstd* decoder) {
    while (!decoder->ended) {
        unsigned char extra;
        ZSTD_outBuffer output = {&extra, 1, 0};
        if (!mg_zstd_step(decoder, &output) || output.pos) { decoder->failed = 1; return 0; }
    }
    if (decoder->input_position != decoder->input_size || decoder->position != decoder->end) {
        decoder->failed = 1; return 0;
    }
    return 1;
}
static hpatch_BOOL mg_zstd_can_open(const char* name) { return strcmp(name, "zstd") == 0; }
static hpatch_decompressHandle mg_zstd_open(hpatch_TDecompress* plugin, hpatch_StreamPos_t expected,
    const hpatch_TStreamInput* source, hpatch_StreamPos_t begin, hpatch_StreamPos_t end) {
    MGState* state = ((MGPlugin*)plugin)->state;
    MGZstd* decoder;
    ZSTD_customMem memory = {mg_allocate, mg_free, state};
    if (begin > end || end > source->streamSize || mg_cancelled(state)) return 0;
    decoder = (MGZstd*)mg_allocate(state, sizeof(MGZstd));
    if (!decoder) return 0;
    memset(decoder, 0, sizeof(*decoder));
    decoder->state = state; decoder->source = source; decoder->position = begin; decoder->end = end; decoder->expected = expected;
    decoder->decoder = ZSTD_createDStream_advanced(memory);
    if (!decoder->decoder) { state->memory_failed = 1; mg_free(state, decoder); return 0; }
    if (mg_zstd_error(decoder, ZSTD_initDStream(decoder->decoder)) ||
        mg_zstd_error(decoder, ZSTD_DCtx_setParameter(decoder->decoder, ZSTD_d_windowLogMax, MG_ZSTD_WINDOW_LOG))) {
        ZSTD_freeDStream(decoder->decoder); mg_free(state, decoder); return 0;
    }
    return decoder;
}
static hpatch_BOOL mg_zstd_part(hpatch_decompressHandle handle, unsigned char* bytes, unsigned char* end) {
    MGZstd* decoder = (MGZstd*)handle;
    ZSTD_outBuffer output = {bytes, (size_t)(end - bytes), 0};
    if (decoder->failed || output.size > decoder->expected - decoder->produced) return hpatch_FALSE;
    while (output.pos < output.size) {
        if (decoder->ended || !mg_zstd_step(decoder, &output)) { decoder->failed = 1; return hpatch_FALSE; }
    }
    decoder->produced += output.pos;
    if (decoder->ended && decoder->produced != decoder->expected) { decoder->failed = 1; return hpatch_FALSE; }
    if (decoder->produced == decoder->expected && !mg_zstd_finish(decoder)) return hpatch_FALSE;
    return hpatch_TRUE;
}
static hpatch_BOOL mg_zstd_close(hpatch_TDecompress* plugin, hpatch_decompressHandle handle) {
    MGZstd* decoder = (MGZstd*)handle;
    int valid = !decoder->failed && decoder->produced == decoder->expected && mg_zstd_finish(decoder);
    (void)plugin;
    ZSTD_freeDStream(decoder->decoder);
    mg_free(decoder->state, decoder);
    return valid ? hpatch_TRUE : hpatch_FALSE;
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
                            uint64_t patch_size, uint64_t new_size, MGHDiffInfo* info,
                            size_t read_step, size_t output_cache_step) {
    MGState state = {callbacks, 0, 0, 0, read_step};
    MGPlugin plugin = {{mg_zstd_can_open, mg_zstd_open, mg_zstd_close, mg_zstd_part, 0, hpatch_dec_ok, 1}, &state};
    MGInput old_input = {&state, callbacks->read_old}, patch_input = {&state, callbacks->read_patch};
    hpatch_TStreamInput old = {&old_input, old_size, mg_read, 0}, patch = {&patch_input, patch_size, mg_read, 0};
    hpatch_TStreamOutput output = {&state, new_size, 0, mg_write};
    hpatch_compressedDiffInfo header;
    _THDiffzHead head;
    unsigned char* cache;
    MGHDiffResult result;
    size_t cache_size;
    if (!read_step || read_step > MG_IO_SIZE || output_cache_step < 512 || output_cache_step > MG_CACHE_STEP_MAX)
        return mg_hdiff_malformed;
    cache_size = 6 * output_cache_step;
    if (mg_cancelled(&state)) return mg_hdiff_cancelled;
    if (!read_diffz_head(&header, &head, &patch)) return mg_cancelled(&state) ? mg_hdiff_cancelled : mg_hdiff_malformed;
    if (header.newDataSize > INT64_MAX || header.oldDataSize > INT64_MAX) return mg_hdiff_malformed;
    info->old_size = header.oldDataSize; info->new_size = header.newDataSize;
    if (header.compressType[0] && strcmp(header.compressType, "zstd") != 0) return mg_hdiff_unsupported_compressor;
    if (header.oldDataSize != old_size) return mg_hdiff_old_size;
    if (header.newDataSize != new_size) return mg_hdiff_new_size;
    if ((!header.compressType[0] && header.compressedCount) || !mg_sections(&head, patch_size)) return mg_hdiff_malformed;
    cache = (unsigned char*)mg_allocate(&state, cache_size);
    if (!cache) return mg_hdiff_memory;
    result = patch_decompress_with_cache(&output, &old, &patch, &plugin.base, cache, cache + cache_size)
             && state.written == new_size ? mg_hdiff_ok : mg_hdiff_malformed;
    mg_free(&state, cache);
    if (mg_cancelled(&state)) return mg_hdiff_cancelled;
    return state.memory_failed ? mg_hdiff_memory : result;
}
