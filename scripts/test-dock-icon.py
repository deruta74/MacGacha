#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
"""Exercise Wine's actual icon-selection block against real NSBundle metadata.

Pass a patched Wine source directory. --expect-legacy proves the same harness
against the unpatched source (all cases must install the Windows icon).
No game, GUI automation, runtime installation or network access is involved.
"""
import argparse
import pathlib
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("--expect-legacy", action="store_true")
    args = parser.parse_args()
    source = (args.source / "dlls/winemac.drv/cocoa_app.m").read_text()
    # Compile the production selection block, not a separately implemented policy.
    block = source.split("[NSApp setWindowsMenu:submenu];", 1)[1].split("\n        }", 1)[0]
    if "setApplicationIconImage:self.applicationIcon" not in block:
        raise RuntimeError("Wine icon-selection block changed; review the harness")
    harness = r'''
#import <Foundation/Foundation.h>
static int calls;
static id supplied;
@interface ProbeApplication : NSObject
- (void)setApplicationIconImage:(id)image;
@end
@implementation ProbeApplication
- (void)setApplicationIconImage:(id)image { calls++; supplied = image; }
@end
static ProbeApplication *NSApp;
@interface Controller : NSObject
- (id)applicationIcon;
- (void)run;
@end
@implementation Controller
- (id)applicationIcon { return @"windows-icon"; }
- (void)run {
''' + block + r'''
}
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSApp = [ProbeApplication new];
        Controller *controller = [Controller new];
        [controller run];
        int expected = atoi(argv[1]);
        if (calls != expected) return 3;
        if (expected && ![supplied isEqual:@"windows-icon"]) return 4;
    }
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="macgacha-icon-policy-") as directory:
        root = pathlib.Path(directory)
        code = root / "probe.m"
        code.write_text(harness)
        binary = root / "probe"
        subprocess.run(["/usr/bin/clang", "-arch", "x86_64", "-Wall", "-Wextra", "-Werror",
                        "-framework", "Foundation", str(code), "-o", str(binary)], check=True)
        for label, enabled in [("absent", None), ("disabled", False), ("enabled", True)]:
            contents = root / (label + ".app") / "Contents"
            executable = contents / "MacOS/probe"
            executable.parent.mkdir(parents=True)
            shutil.copy2(binary, executable)
            info = {"CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
                    "CFBundleIdentifier": "com.lo7ted.icon-policy-test." + label}
            if enabled is not None:
                info["MacGachaPreserveBundleIcon"] = enabled
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            expected = 1 if args.expect_legacy or enabled is not True else 0
            subprocess.run([str(executable), str(expected)], check=True)
            print(f"{label}: {'Windows icon retained' if expected else 'bundle icon preserved'}")


if __name__ == "__main__":
    main()
