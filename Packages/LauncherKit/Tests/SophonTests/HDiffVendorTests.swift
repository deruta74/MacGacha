// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import CHDiffPatch

@Suite struct HDiffVendorTests {
    @Test func pinnedDecoderRecognizesHDiff13Header() {
        // new=3, old=2, covers=0; four (decoded, compressed) section sizes.
        let patch = Data("HDIFF13&\0".utf8) + Data([3, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0]) + Data("new".utf8)
        var info = hpatch_compressedDiffInfo()
        let valid = patch.withUnsafeBytes { bytes in
            let start = bytes.bindMemory(to: UInt8.self).baseAddress!
            return getCompressedDiffInfo_mem(&info, start, start + bytes.count)
        }
        #expect(valid != 0)
        #expect(info.newDataSize == 3)
        #expect(info.oldDataSize == 2)
        #expect(info.compressedCount == 0)
    }
}
