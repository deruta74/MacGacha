// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI

struct PurgeableSpaceHint: View {
    let bytes: Int64

    var body: some View {
        Text("\(ByteSize.text(bytes)) of the free space Finder shows is held by macOS (Time Machine snapshots and caches) and can't be used yet. macOS frees it over time, or you can free it in System Settings › General › Storage.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
