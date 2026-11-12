// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

/// The consented graphics payload. Wine and all other libraries come from the Wine component.
enum D3DMetalGraphics {
    static let paths: [SafeRelativePath] = (
        ["bin/wine", "lib/external", "yaagl-d3dmetal-runtime.json"]
        + ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx", "amd_fidelityfx_framegeneration_dx12_native"].map { "lib/wine/x86_64-windows/\($0).dll" }
        + ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi", "nvapi64", "nvngx-on-metalfx", "nvngx"].map { "lib/wine/x86_64-unix/\($0).so" }
    ).map { try! SafeRelativePath($0) }
}
