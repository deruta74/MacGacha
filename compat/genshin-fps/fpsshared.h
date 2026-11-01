// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE.
#ifndef MACGACHA_FPS_SHARED_H
#define MACGACHA_FPS_SHARED_H
#include <stdint.h>
#include <stddef.h>

enum { FPS_VERSION = 1, FPS_NONE = 0, FPS_READY = 1, FPS_ERROR = 2, FPS_STOP = 3 };
enum { FPS_BAD_IMAGE = 1, FPS_SCAN_FAILED, FPS_AMBIGUOUS, FPS_BAD_SLOT,
       FPS_BAD_TARGET, FPS_BAD_INITIAL = 12 };

/* Win64 ABI, including four padding bytes at 36 and at 60. Publish payload
   before a release status store; readers acquire status before reading it. */
typedef struct {
    uint32_t version;
    volatile uint32_t status, error;
    volatile int32_t target, observed;
    volatile uint32_t resets, heartbeat, qualifying, distinct_slots;
    uint64_t slot_rva, caller_rva;
    int32_t initial;
} FpsShared;
_Static_assert(sizeof(FpsShared) == 64, "shared ABI size");
_Static_assert(offsetof(FpsShared, status) == 4, "shared status offset");
_Static_assert(offsetof(FpsShared, target) == 12, "shared target offset");
_Static_assert(offsetof(FpsShared, slot_rva) == 40, "shared slot offset");
_Static_assert(offsetof(FpsShared, caller_rva) == 48, "shared caller offset");
_Static_assert(offsetof(FpsShared, initial) == 56, "shared initial offset");

static inline uint32_t fps_status(const FpsShared *s) {
    return __atomic_load_n(&s->status, __ATOMIC_ACQUIRE);
}
static inline void fps_stop(FpsShared *s) {
    __atomic_store_n(&s->target, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&s->status, FPS_STOP, __ATOMIC_RELEASE);
}
static inline void fps_error(FpsShared *s, uint32_t error) {
    __atomic_store_n(&s->error, error, __ATOMIC_RELAXED);
    uint32_t expected = FPS_NONE;
    if (!__atomic_compare_exchange_n(&s->status, &expected, FPS_ERROR, 0,
                                    __ATOMIC_RELEASE, __ATOMIC_ACQUIRE) && expected == FPS_READY) {
        __atomic_compare_exchange_n(&s->status, &expected, FPS_ERROR, 0,
                                    __ATOMIC_RELEASE, __ATOMIC_ACQUIRE);
    }
}
#endif
