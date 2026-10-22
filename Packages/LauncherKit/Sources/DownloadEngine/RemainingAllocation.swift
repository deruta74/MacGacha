// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Additional allocation for the remaining session, including its bounded
/// prefetch window. Resident parts/output are already reflected in free space.
/// Every admission reserves ALL remaining output, so out-of-order assembly and
/// a retained surprise fallback cannot steal a later file's allocation.
/// Updates visit an object's remaining references; maxima use a segment tree.
package struct RemainingAllocation {
    private struct Part {
        var indexes: Set<Int> = []
        var cost: Int64 = 0
        var slot: Int64 = 0
        var forced = false
        var stickyShared = false
        var residentSize: Int64 = 0
    }
    private var parts: [String: Part] = [:]
    private let planned: Set<String>
    private let external: Set<String>
    private let limit: Int
    private let pipeline: PipelineConfiguration
    private let indexes: [SafeRelativePath: Int]
    private var fileCosts: [Int64]
    private var finished = Set<Int>()
    private var decoded: Int64 = 0, missing: Int64 = 0, shared: Int64 = 0, residentWindow: Int64 = 0
    private var peak: AllocationEnvelope
    private var heap: [Int64] = []
    private var costCounts: [Int64: Int] = [:]

    package init(files: [FileTask], costs: [String: Int64], retainedObjects: Set<String>, limit: Int,
        pipeline: PipelineConfiguration = .default) throws {
        try pipeline.validate()
        guard limit > 0 else { throw LauncherError.io("Invalid object concurrency limit") }
        planned = Set(costs.keys)
        self.limit = limit; self.pipeline = pipeline; external = retainedObjects
        indexes = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.element.path, $0.offset) })
        fileCosts = Array(repeating: 0, count: files.count); peak = AllocationEnvelope(fileCosts)
        for (index, file) in files.enumerated() {
            decoded = try SpaceBudget.adding(decoded, file.size)
            for id in SpaceBudget.references(file) { parts[id, default: Part()].indexes.insert(index) }
        }
        for id in Array(parts.keys) {
            let shared = external.contains(id) || parts[id]!.indexes.count > 1
            parts[id]?.stickyShared = shared
        }
        for (id, cost) in costs { try change(id, to: cost, force: false) }
    }
    package mutating func setCost(_ id: String, to cost: Int64) throws {
        // An unpredicted fallback (or a corrupt part being refetched) is not
        // constrained by the original window. Reserve it in full before fetch.
        try change(id, to: cost, force: cost > 0 && (parts[id]?.cost ?? 0) == 0 && !planned.contains(id))
    }
    private func retained(_ id: String, _ part: Part) -> Bool { part.stickyShared || part.forced }
    private mutating func change(_ id: String, to cost: Int64, force: Bool) throws {
        guard var part = parts.removeValue(forKey: id), !part.indexes.isEmpty else { return }
        if cost == part.cost, !force || part.forced { parts[id] = part; return }
        let wasShared = retained(id, part), old = part.cost, oldSlot = part.slot
        if cost == 0, old > 0 {
            // Only this session's transfers occupy its reserved window.
            // Initially cached parts have no cost/slot and supply no credit.
            part.residentSize = old
            if !wasShared { residentWindow = try SpaceBudget.adding(residentWindow, old) }
        } else if cost > 0 {
            if part.residentSize > 0, !wasShared { residentWindow -= part.residentSize }
            part.residentSize = 0
        }
        part.forced = part.forced || force; part.cost = cost
        let isShared = retained(id, part)
        // A completed transfer still occupies its prefetch slot until assembly
        // finishes. Removing its slot AND crediting its bytes would count the
        // same disk space twice, especially for an oversized file.
        part.slot = isShared ? 0 : max(part.slot, cost)
        missing = try SpaceBudget.adding(missing, cost - old)
        if wasShared { shared -= old }
        if isShared { shared = try SpaceBudget.adding(shared, cost) }
        for index in part.indexes {
            fileCosts[index] = try SpaceBudget.adding(fileCosts[index], part.slot - oldSlot)
            try peak.add(from: index, through: index, value: part.slot - oldSlot)
        }
        if oldSlot > 0 { costCounts[oldSlot, default: 0] -= 1 }
        if part.slot > 0 { costCounts[part.slot, default: 0] += 1; push(part.slot) }
        parts[id] = part
    }
    package mutating func finish(_ file: FileTask) throws {
        guard let index = indexes[file.path], finished.insert(index).inserted else { return }
        decoded -= file.size
        for id in SpaceBudget.references(file) {
            guard var part = parts.removeValue(forKey: id) else { continue }
            let oldShared = retained(id, part), cost = part.cost
            part.indexes.remove(index)
            if oldShared { shared -= cost }
            if part.indexes.isEmpty {
                if !oldShared { residentWindow -= part.residentSize }
                missing -= cost
                if part.slot > 0 { costCounts[part.slot, default: 0] -= 1 }
                part.slot = 0
                part.cost = 0
            } else if retained(id, part) { shared += cost }
            parts[id] = part
        }
        try peak.add(from: index, through: index, value: -fileCosts[index]); fileCosts[index] = 0
    }
    package mutating func disk(written: Int64 = 0, partialParts: [String: Int64] = [:]) throws -> Int64 {
        while let largest = heap.first, costCounts[largest, default: 0] == 0 { pop() }
        let fileParts = indexes.isEmpty ? 0 : try peak.maximum(from: 0)
        var partialShared: Int64 = 0, partialWindow: Int64 = 0
        for (id, bytes) in partialParts {
            guard let part = parts[id] else { continue }
            let occupied = min(part.cost, bytes)
            if retained(id, part) { partialShared += occupied } else { partialWindow += occupied }
        }
        return try SpaceBudget.peakDisk(decoded: max(0, decoded - written), parts: missing - partialShared - partialWindow, shared: shared - partialShared,
            largestObject: heap.first ?? 0, largestFileParts: fileParts, limit: limit, pipeline: pipeline, occupiedWindow: residentWindow + partialWindow)
    }
    private mutating func push(_ value: Int64) {
        heap.append(value); var i = heap.count - 1
        while i > 0 { let p = (i - 1) / 2; if heap[p] >= heap[i] { break }; heap.swapAt(p, i); i = p }
    }
    private mutating func pop() {
        if heap.count == 1 { heap.removeLast(); return }
        heap[0] = heap.removeLast(); var i = 0
        while i * 2 + 1 < heap.count {
            var child = i * 2 + 1
            if child + 1 < heap.count, heap[child + 1] > heap[child] { child += 1 }
            if heap[i] >= heap[child] { break }; heap.swapAt(i, child); i = child
        }
    }
}

/// Lazy range-add/max tree. Parent offsets need not be pushed to children:
/// partial updates and queries add the parent's offset to the child maximum.
private struct AllocationEnvelope {
    private let count: Int
    private var values: [Int64]
    private var offsets: [Int64]
    init(_ prefixes: [Int64]) {
        count = prefixes.count
        values = Array(repeating: 0, count: max(1, count * 4))
        offsets = values
        if count > 0 { build(prefixes, node: 1, low: 0, high: count - 1) }
    }
    private mutating func build(_ prefixes: [Int64], node: Int, low: Int, high: Int) {
        if low == high { values[node] = prefixes[low]; return }
        let middle = (low + high) / 2
        build(prefixes, node: node * 2, low: low, high: middle)
        build(prefixes, node: node * 2 + 1, low: middle + 1, high: high)
        values[node] = max(values[node * 2], values[node * 2 + 1])
    }
    mutating func add(from first: Int, through last: Int, value: Int64) throws {
        guard count > 0 else { return }
        try add(first, last, value, node: 1, low: 0, high: count - 1)
    }
    private mutating func add(_ first: Int, _ last: Int, _ value: Int64, node: Int, low: Int, high: Int) throws {
        if first <= low && high <= last {
            values[node] = try SpaceBudget.adding(values[node], value)
            offsets[node] = try SpaceBudget.adding(offsets[node], value)
            return
        }
        let middle = (low + high) / 2
        if first <= middle { try add(first, last, value, node: node * 2, low: low, high: middle) }
        if last > middle { try add(first, last, value, node: node * 2 + 1, low: middle + 1, high: high) }
        values[node] = try SpaceBudget.adding(max(values[node * 2], values[node * 2 + 1]), offsets[node])
    }
    func maximum(from first: Int) throws -> Int64 {
        try maximum(first, node: 1, low: 0, high: count - 1)
    }
    private func maximum(_ first: Int, node: Int, low: Int, high: Int) throws -> Int64 {
        if first <= low { return values[node] }
        let middle = (low + high) / 2
        let right = try maximum(first, node: node * 2 + 1, low: middle + 1, high: high)
        let child = first <= middle ? try max(right, maximum(first, node: node * 2, low: low, high: middle)) : right
        return try SpaceBudget.adding(child, offsets[node])
    }
}
