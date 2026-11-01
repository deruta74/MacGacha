// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <wchar.h>
#include "fpsshared.h"

static HANDLE stop_event, finished_event;
static void report(const char *format, ...) {
    SYSTEMTIME t; GetSystemTime(&t);
    printf("%04u-%02u-%02uT%02u:%02u:%02u.%03uZ ", t.wYear, t.wMonth, t.wDay,
           t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list args; va_start(args, format); vprintf(format, args); va_end(args);
    putchar('\n'); fflush(stdout);
}
static BOOL WINAPI control(DWORD event) {
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT && event != CTRL_CLOSE_EVENT &&
        event != CTRL_LOGOFF_EVENT && event != CTRL_SHUTDOWN_EVENT) return FALSE;
    SetEvent(stop_event);
    /* Close handlers have a short OS deadline. Main owns the shared view and
       hook; ask it to clean up rather than racing its unmap from this thread. */
    if (event != CTRL_C_EVENT && event != CTRL_BREAK_EVENT) WaitForSingleObject(finished_event, 3000);
    return TRUE;
}
static int decimal(const char *s, unsigned min, unsigned max, unsigned *out) {
    unsigned n = 0;
    if (!*s) return 0;
    for (; *s; ++s) {
        if (*s < '0' || *s > '9' || n > max / 10) return 0;
        n = n * 10 + (unsigned)(*s - '0');
        if (n > max) return 0;
    }
    if (n < min) return 0;
    *out = n; return 1;
}
static int game_name(const WCHAR *s) {
    return !_wcsicmp(s, L"GenshinImpact.exe") || !_wcsicmp(s, L"YuanShen.exe");
}
static int find_game(DWORD *pid) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return -1;
    PROCESSENTRY32W entry = {0}; entry.dwSize = sizeof(entry);
    unsigned count = 0;
    BOOL more = Process32FirstW(snapshot, &entry);
    int valid = more || GetLastError() == ERROR_NO_MORE_FILES;
    while (more) {
        if (game_name(entry.szExeFile)) { if (count < 2) ++count; *pid = entry.th32ProcessID; }
        more = Process32NextW(snapshot, &entry);
        if (!more && GetLastError() != ERROR_NO_MORE_FILES) valid = 0;
    }
    CloseHandle(snapshot);
    return valid ? (int)count : -1;
}
typedef struct { DWORD pid, thread; HWND window; } Window;
static BOOL CALLBACK find_window(HWND window, LPARAM context) {
    Window *found = (Window *)context;
    DWORD pid = 0, thread = GetWindowThreadProcessId(window, &pid);
    WCHAR name[64];
    if (!found->window && thread && pid == found->pid && IsWindowVisible(window) &&
        GetClassNameW(window, name, 64) && !_wcsicmp(name, L"UnityWndClass")) {
        found->window = window; found->thread = thread;
    }
    return TRUE;
}
/* 0: timeout, 1: game exited, 2: stop requested, -1: wait failed. */
static int wait_game(HANDLE game, DWORD milliseconds) {
    HANDLE events[] = { game, stop_event };
    DWORD result = WaitForMultipleObjects(2, events, FALSE, milliseconds);
    if (result == WAIT_TIMEOUT) return 0;
    if (result == WAIT_OBJECT_0) return 1;
    if (result == WAIT_OBJECT_0 + 1) return 2;
    return -1;
}
static void details(const FpsShared *s) {
    report("status=%u error=%u slot-rva=0x%llx caller-rva=0x%llx qualifying=%u distinct-slots=%u initial=%d",
        fps_status(s), __atomic_load_n(&s->error, __ATOMIC_RELAXED),
        (unsigned long long)s->slot_rva, (unsigned long long)s->caller_rva,
        __atomic_load_n(&s->qualifying, __ATOMIC_RELAXED),
        __atomic_load_n(&s->distinct_slots, __ATOMIC_RELAXED), s->initial);
}

int main(int argc, char **argv) {
    unsigned target = 0, seconds = 120; int deadline_seen = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--target") && !target && i + 1 < argc && decimal(argv[i + 1], 61, 360, &target)) { ++i; continue; }
        if (!strcmp(argv[i], "--deadline-seconds") && !deadline_seen && i + 1 < argc &&
            decimal(argv[i + 1], 1, 600, &seconds)) { deadline_seen = 1; ++i; continue; }
        report("exit=13 reason=invalid-arguments"); return 13;
    }
    if (!target) { report("exit=13 reason=target-required"); return 13; }
    int code = 13; const char *reason = "setup-failed";
    HANDLE game = NULL, mapping = NULL;
    HMODULE module = NULL; HHOOK hook = NULL; FpsShared *shared = NULL;
    stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    finished_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!stop_event || !finished_event || !SetConsoleCtrlHandler(control, TRUE)) goto done;
    report("mode=in-process target=%u deadline-seconds=%u signature=unlocker35-il2cpp-e9-v2", target, seconds);
    DWORD pid = 0;
    int count = find_game(&pid);
    if (count != 1) {
        code = count == 0 ? 10 : count > 1 ? 11 : 13;
        reason = count == 0 ? "no-game" : count > 1 ? "multiple-games" : "process-snapshot-failed";
        goto done;
    }
    game = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!game) { reason = "open-process-failed"; goto done; }
    WCHAR path[32768]; DWORD length = 32768;
    if (!QueryFullProcessImageNameW(game, 0, path, &length)) { reason = "process-identity-failed"; goto done; }
    const WCHAR *base = wcsrchr(path, L'\\');
    if (!game_name(base ? base + 1 : path)) { reason = "process-identity-changed"; goto done; }
    ULONGLONG deadline = GetTickCount64() + (ULONGLONG)seconds * 1000;
    Window window = { pid, 0, NULL };
    while (!window.window) {
        int wait = wait_game(game, 100);
        if (wait) { code = wait > 0 ? 0 : 13; reason = wait == 1 ? "game-exited" : wait == 2 ? "stopped" : "wait-failed"; goto done; }
        if (GetTickCount64() >= deadline) { code = 11; reason = "window-deadline"; goto done; }
        if (!EnumWindows(find_window, (LPARAM)&window)) { reason = "window-enumeration-failed"; goto done; }
    }
    DWORD current = 0;
    if (find_game(&current) != 1 || current != pid || wait_game(game, 0) != 0) {
        code = 11; reason = "game-set-changed"; goto done;
    }
    WCHAR name[80];
    swprintf(name, 80, L"Local\\MacGachaFpsUnlock-%lu", (unsigned long)pid);
    mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(FpsShared), name);
    DWORD mapping_error = GetLastError();
    if (!mapping || mapping_error == ERROR_ALREADY_EXISTS) {
        code = mapping_error == ERROR_ALREADY_EXISTS ? 11 : 13;
        reason = "shared-memory-unavailable"; goto done;
    }
    shared = MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(FpsShared));
    if (!shared) { reason = "shared-memory-map-failed"; goto done; }
    memset(shared, 0, sizeof(*shared)); shared->version = FPS_VERSION;
    __atomic_store_n(&shared->target, (int32_t)target, __ATOMIC_RELEASE);
    length = GetModuleFileNameW(NULL, path, 32768);
    if (!length || length >= 32768) { reason = "stub-location-unavailable"; goto done; }
    WCHAR *slash = wcsrchr(path, L'\\');
    if (!slash || (size_t)(slash + 1 - path) + 12 >= 32768) {
        reason = "stub-location-unavailable"; goto done;
    }
    wcscpy(slash + 1, L"fpsstub.dll");
    module = LoadLibraryW(path); // Absolute adjacent path, never a DLL search name.
    if (!module) { code = 11; reason = "load-stub-failed"; goto done; }
    union { FARPROC raw; HOOKPROC hook; } proc;
    proc.raw = GetProcAddress(module, "MacGachaFpsHook");
    if (!proc.raw) { code = 11; reason = "hook-export-missing"; goto done; }
    hook = SetWindowsHookExW(WH_GETMESSAGE, proc.hook, module, window.thread);
    if (!hook || !PostThreadMessageW(window.thread, WM_NULL, 0, 0)) { code = 11; reason = "hook-install-failed"; goto done; }
    report("status=waiting pid=%lu thread=%lu", (unsigned long)pid, (unsigned long)window.thread);
    ULONGLONG next_post = GetTickCount64() + 1000;
    for (;;) {
        int wait = wait_game(game, 50);
        if (wait) { code = wait > 0 ? 0 : 13; reason = wait == 1 ? "game-exited" : wait == 2 ? "stopped" : "wait-failed"; goto done; }
        uint32_t status = fps_status(shared);
        if (status == FPS_READY || status == FPS_ERROR) {
            details(shared);
            if (status == FPS_ERROR) {
                code = shared->error == FPS_BAD_INITIAL ? 12 : 11; reason = "stub-error"; goto done;
            }
            if (shared->initial != -1 && (shared->initial < 30 || shared->initial > 60)) { code = 12; reason = "bad-initial-value"; goto done; }
            break;
        }
        if (status != FPS_NONE) { code = 11; reason = "unexpected-shared-status"; goto done; }
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) { code = 11; reason = "ready-deadline"; goto done; }
        if (now >= next_post) {
            if (!PostThreadMessageW(window.thread, WM_NULL, 0, 0)) { code = 11; reason = "hook-message-failed"; goto done; }
            next_post = now + 1000;
        }
    }
    uint32_t heartbeat = __atomic_load_n(&shared->heartbeat, __ATOMIC_RELAXED);
    ULONGLONG last_advance = GetTickCount64(); int stalled = 0;
    for (;;) {
        int wait = wait_game(game, 1000);
        if (wait) { code = wait > 0 ? 0 : 13; reason = wait == 1 ? "game-exited" : wait == 2 ? "stopped" : "wait-failed"; goto done; }
        if (fps_status(shared) != FPS_READY) { details(shared); code = 11; reason = "stub-stopped-or-failed"; goto done; }
        uint32_t next = __atomic_load_n(&shared->heartbeat, __ATOMIC_RELAXED);
        ULONGLONG now = GetTickCount64();
        if (next != heartbeat) { heartbeat = next; last_advance = now; stalled = 0; }
        report("status=holding observed=%d resets=%u heartbeat=%u",
            __atomic_load_n(&shared->observed, __ATOMIC_RELAXED),
            __atomic_load_n(&shared->resets, __ATOMIC_RELAXED), heartbeat);
        if (now - last_advance > 5000 && !stalled) { report("status=stalled heartbeat=%u", heartbeat); stalled = 1; }
    }
done:
    if (shared) fps_stop(shared);
    if (hook) UnhookWindowsHookEx(hook);
    if (module) FreeLibrary(module);
    if (shared) UnmapViewOfFile(shared);
    if (mapping) CloseHandle(mapping);
    if (game) CloseHandle(game);
    report("exit=%d reason=%s", code, reason);
    if (finished_event) SetEvent(finished_event);
    /* These two events belong to the control handler too. Process exit closes
       them after all threads stop, avoiding close-versus-wait races. */
    return code;
}
