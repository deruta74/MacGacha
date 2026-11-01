// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include "fpsshared.h"

#define MAX_SECTIONS 96
#define MAX_SLOTS 256
#define BLOCK 65536
typedef struct {
    uintptr_t base;
    size_t size;
    WORD count;
    IMAGE_SECTION_HEADER sections[MAX_SECTIONS];
} Image;

static int read_self(uintptr_t at, void *out, size_t size) {
    SIZE_T got = 0;
    return at <= UINTPTR_MAX - size &&
        ReadProcessMemory(GetCurrentProcess(), (LPCVOID)at, out, size, &got) && got == size;
}
static int contains(const Image *image, uintptr_t at, size_t size) {
    return at >= image->base && size <= image->size && at - image->base <= image->size - size;
}
static int in_section(const Image *image, uintptr_t at, size_t size, DWORD flags) {
    if (!contains(image, at, size)) return 0;
    size_t offset = at - image->base;
    for (WORD i = 0; i < image->count; ++i) {
        const IMAGE_SECTION_HEADER *s = &image->sections[i];
        size_t start = s->VirtualAddress, length = s->Misc.VirtualSize;
        if ((s->Characteristics & flags) == flags && offset >= start && size <= length &&
            offset - start <= length - size) return 1;
    }
    return 0;
}
static int read_image(const Image *image, uintptr_t at, void *out, size_t size) {
    return contains(image, at, size) && read_self(at, out, size);
}
static int load_image(Image *image) {
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 nt;
    image->base = (uintptr_t)GetModuleHandleW(NULL);
    if (!image->base || !read_self(image->base, &dos, sizeof(dos)) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < (LONG)sizeof(dos) ||
        dos.e_lfanew > (1 << 20) || image->base > UINTPTR_MAX - (uintptr_t)dos.e_lfanew) return 0;
    uintptr_t pe = image->base + (uintptr_t)dos.e_lfanew;
    if (!read_self(pe, &nt, sizeof(nt)) || nt.Signature != IMAGE_NT_SIGNATURE ||
        nt.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        nt.FileHeader.SizeOfOptionalHeader != sizeof(IMAGE_OPTIONAL_HEADER64) ||
        !nt.FileHeader.NumberOfSections || nt.FileHeader.NumberOfSections > MAX_SECTIONS ||
        !nt.OptionalHeader.SizeOfImage || nt.OptionalHeader.SizeOfImage > (1ULL << 31)) return 0;
    image->size = nt.OptionalHeader.SizeOfImage;
    if (image->base > UINTPTR_MAX - image->size) return 0;
    image->count = nt.FileHeader.NumberOfSections;
    if (!read_image(image, pe + sizeof(nt), image->sections, image->count * sizeof(image->sections[0]))) return 0;
    for (WORD i = 0; i < image->count; ++i) {
        const IMAGE_SECTION_HEADER *s = &image->sections[i];
        if (s->VirtualAddress > image->size || s->Misc.VirtualSize > image->size - s->VirtualAddress) return 0;
    }
    return 1;
}
static int relative_target(uintptr_t next, int32_t disp, uintptr_t *out) {
    int64_t d = disp;
    if (d < 0) { if (next < (uint64_t)-d) return 0; *out = next - (uintptr_t)-d; }
    else { if (next > UINTPTR_MAX - (uintptr_t)d) return 0; *out = next + (uintptr_t)d; }
    return 1;
}
static int writable_slot(const Image *image, uintptr_t slot) {
    MEMORY_BASIC_INFORMATION info;
    if (slot % 4 || !in_section(image, slot, 4, IMAGE_SCN_MEM_WRITE) ||
        in_section(image, slot, 4, IMAGE_SCN_MEM_EXECUTE) ||
        VirtualQuery((LPCVOID)slot, &info, sizeof(info)) != sizeof(info)) return 0;
    DWORD p = info.Protect & 0xff;
    return info.State == MEM_COMMIT && info.Type == MEM_IMAGE &&
        (uintptr_t)info.AllocationBase == image->base && !(info.Protect & PAGE_GUARD) &&
        (p == PAGE_READWRITE || p == PAGE_WRITECOPY) && slot >= (uintptr_t)info.BaseAddress &&
        info.RegionSize >= 4 && slot - (uintptr_t)info.BaseAddress <= info.RegionSize - 4;
}

/* unlocker35-il2cpp-e9-v2. All addresses remain in the main image; no
   disassembly guesses, code writes or page-protection changes. */
static int resolve(const Image *image, uintptr_t caller, uintptr_t *slot) {
    BYTE bytes[10]; int32_t disp; uintptr_t at, visited[9];
    if (!read_image(image, caller, bytes, sizeof(bytes)) || memcmp(bytes, "\xb9\x3c\0\0\0\xe8", 6)) return 0;
    memcpy(&disp, bytes + 6, 4);
    if (!relative_target(caller + 10, disp, &at)) return 0;
    for (unsigned depth = 0; depth < 9; ++depth) {
        BYTE code[7];
        for (unsigned j = 0; j < depth; ++j) if (visited[j] == at) return 0;
        visited[depth] = at;
        if (!in_section(image, at, sizeof(code), IMAGE_SCN_MEM_EXECUTE) ||
            !read_image(image, at, code, sizeof(code)) || (depth == 0 && code[0] != 0xe9)) return 0;
        if (code[0] == 0xe8 || code[0] == 0xe9) {
            if (depth == 8) return 0;
            memcpy(&disp, code + 1, 4);
            if (!relative_target(at + 5, disp, &at)) return 0;
            continue;
        }
        if (code[0] != 0x89 || code[1] != 0x0d || code[6] != 0xc3) return 0;
        memcpy(&disp, code + 2, 4);
        return relative_target(at + 6, disp, slot) && writable_slot(image, *slot);
    }
    return 0;
}
static int scan(const Image *image, FpsShared *shared, uintptr_t *chosen) {
    BYTE bytes[BLOCK + 9]; uintptr_t slots[MAX_SLOTS];
    uint32_t qualifying = 0, distinct = 0;
    for (WORD i = 0; i < image->count; ++i) {
        const IMAGE_SECTION_HEADER *s = &image->sections[i];
        if (memcmp(s->Name, "il2cpp\0", 8) || !(s->Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        for (size_t offset = 0; offset < s->Misc.VirtualSize;) {
            if (fps_status(shared) == FPS_STOP) return 0;
            size_t remaining = s->Misc.VirtualSize - offset;
            size_t length = remaining < sizeof(bytes) ? remaining : sizeof(bytes);
            size_t advance = remaining < BLOCK ? remaining : BLOCK;
            uintptr_t start = image->base + s->VirtualAddress + offset;
            /* Do not skip unreadable bytes: that would invalidate uniqueness. */
            if (!read_image(image, start, bytes, length)) return 0;
            for (size_t j = 0; j < advance && j + 10 <= length; ++j) {
                uintptr_t slot;
                if (memcmp(bytes + j, "\xb9\x3c\0\0\0\xe8", 6) || !resolve(image, start + j, &slot)) continue;
                if (!qualifying) {
                    *chosen = slot; shared->slot_rva = slot - image->base;
                    shared->caller_rva = start + j - image->base;
                }
                shared->qualifying = ++qualifying;
                uint32_t k;
                for (k = 0; k < distinct; ++k) if (slots[k] == slot) break;
                if (k == distinct) {
                    if (k == MAX_SLOTS) return 0;
                    slots[k] = slot; shared->distinct_slots = ++distinct;
                }
            }
            offset += advance;
        }
    }
    return qualifying ? (distinct == 1 ? 1 : -1) : 0;
}

static DWORD WINAPI worker(void *unused) {
    (void)unused;
    WCHAR name[80];
    swprintf(name, 80, L"Local\\MacGachaFpsUnlock-%lu", (unsigned long)GetCurrentProcessId());
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, name);
    if (!mapping) return 0;
    FpsShared *shared = MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(FpsShared));
    if (!shared) { CloseHandle(mapping); return 0; }
    Image image; uintptr_t slot = 0;
    if (shared->version != FPS_VERSION || fps_status(shared) != FPS_NONE) goto done;
    if (!load_image(&image)) { fps_error(shared, FPS_BAD_IMAGE); goto done; }
    int result = scan(&image, shared, &slot);
    if (!result) { fps_error(shared, FPS_SCAN_FAILED); goto done; }
    if (result < 0) { fps_error(shared, FPS_AMBIGUOUS); goto done; }
    if (!writable_slot(&image, slot)) { fps_error(shared, FPS_BAD_SLOT); goto done; }
    shared->initial = shared->observed = *(volatile int32_t *)slot;
    /* -1 is Unity's unset targetFrameRate: the game hasn't applied its own limit yet. */
    if (shared->initial != -1 && (shared->initial < 30 || shared->initial > 60)) { fps_error(shared, FPS_BAD_INITIAL); goto done; }
    uint32_t expected = FPS_NONE;
    if (!__atomic_compare_exchange_n(&shared->status, &expected, FPS_READY, 0,
                                    __ATOMIC_RELEASE, __ATOMIC_ACQUIRE)) goto done;
    while (fps_status(shared) == FPS_READY) {
        int32_t target = __atomic_load_n(&shared->target, __ATOMIC_ACQUIRE);
        if (target != 0) {
            if (target < 61 || target > 360) { fps_error(shared, FPS_BAD_TARGET); break; }
            if (!writable_slot(&image, slot)) { fps_error(shared, FPS_BAD_SLOT); break; }
            int32_t observed = *(volatile int32_t *)slot;
            if (observed != target) {
                __atomic_store_n(&shared->observed, observed, __ATOMIC_RELAXED);
                __atomic_add_fetch(&shared->resets, 1, __ATOMIC_RELAXED);
                if (fps_status(shared) != FPS_READY) break;
                if (__atomic_load_n(&shared->target, __ATOMIC_ACQUIRE) == target) *(volatile int32_t *)slot = target;
            }
        }
        __atomic_add_fetch(&shared->heartbeat, 1, __ATOMIC_RELAXED);
        Sleep(62);
    }
done:
    UnmapViewOfFile(shared); CloseHandle(mapping);
    return 0;
}

__declspec(dllexport) LRESULT CALLBACK MacGachaFpsHook(int code, WPARAM wparam, LPARAM lparam) {
    return CallNextHookEx(NULL, code, wparam, lparam);
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    WCHAR path[32768];
    DWORD length = GetModuleFileNameW(NULL, path, 32768);
    if (!length || length >= 32768) return TRUE;
    const WCHAR *base = wcsrchr(path, L'\\');
    base = base ? base + 1 : path;
    if (_wcsicmp(base, L"GenshinImpact.exe") && _wcsicmp(base, L"YuanShen.exe")) return TRUE;
    DisableThreadLibraryCalls(instance);
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           (LPCWSTR)(const void *)instance, &pinned)) return FALSE;
    HANDLE thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (!thread) return FALSE;
    CloseHandle(thread);
    return TRUE;
}
