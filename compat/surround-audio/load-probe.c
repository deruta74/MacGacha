/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* MacGacha — https://github.com/deruta74/MacGacha */
/* Synthetic dyld check only: never call a Wine entry point. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    void *module;
    if (argc != 2) return 2;
    if (!(module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)))
    {
        fprintf(stderr, "module load failed: %s\n", dlerror());
        return 1;
    }
    if (!dlsym(module, "__wine_unix_call_funcs") || !dlsym(module, "__wine_unix_call_wow64_funcs")) return 1;
    if (dlclose(module)) return 1;
    puts("PASS: Unix-call exports and synthetic dyld load; no Wine entry point called");
    return 0;
}
