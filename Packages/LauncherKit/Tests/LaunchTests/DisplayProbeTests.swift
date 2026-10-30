// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import Launch

@Suite struct DisplayProbeTests {
    @Test func orderingPutsMainFirstAndDropsMirrorsWithoutSortingOthers() {
        let a = ConnectedDisplay(id: "a", name: "", isMain: false)
        let b = ConnectedDisplay(id: "b", name: "", isMain: true)
        let c = ConnectedDisplay(id: "c", name: "", isMain: false)
        let mirror = ConnectedDisplay(id: "mirror", name: "", isMain: false)
        #expect(SystemDisplayProbe.ordered([(a, false), (mirror, true), (b, false), (c, false)]) == [b, a, c])
        #expect(SystemDisplayProbe.ordered([]).isEmpty)
    }

}
