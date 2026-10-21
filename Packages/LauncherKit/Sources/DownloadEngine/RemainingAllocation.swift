// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Ordered allocation envelope. Each leaf is the decoded prefix through a file
/// plus all admitted parts alive at that file: first referrer through last
/// referrer (through session end for outside-session references). All a file's
/// parts are conservatively present before any of its output is written.
///
/// Resident parts keep their lifetime in the envelope; their actual bytes are
/// subtracted from the requirement. After cleanup their lifetime no longer
/// intersects the queried suffix. Thus a resident part occupies its existing
/// slot rather than charging that slot again for future transfers. Already
/// completed output and the current output prefix are likewise subtracted.
/// New fallbacks extend the envelope before allocation. Without a new admission,
/// the suffix maximum cannot increase, so an accepted preflight stays sufficient.
/// Range additions and suffix maxima cost O(log files); construction visits
/// each reference once. No checkpoint scans the remaining plan.
package struct RemainingAllocation {
    private struct Part {
        let first: Int
        var last: Int
        var size: Int64 = 0
        var resident = false
    }
    private var parts: [String: Part] = [:]
    private let external: Set<String>
    private let count: Int
    private var cursor = 0
    private var finishedDecoded: Int64 = 0
    private var residentBytes: Int64 = 0
    private var peak: AllocationEnvelope

    package init(files: [FileTask], costs: [String: Int64], retainedObjects: Set<String>, limit: Int) throws {
        guard limit > 0 else { throw LauncherError.io("Invalid object concurrency limit") }
        external = retainedObjects; count = files.count
        var prefixes: [Int64] = [], decoded: Int64 = 0
        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { throw LauncherError.cancelled }
            decoded = try SpaceBudget.adding(decoded, file.size)
            prefixes.append(decoded)
            for id in SpaceBudget.references(file) {
                if parts[id] == nil { parts[id] = Part(first: index, last: index) }
                else { parts[id]?.last = index }
            }
        }
        peak = AllocationEnvelope(prefixes)
        for (id, cost) in costs { try setCost(id, to: cost) }
    }

    /// Positive cost admits a missing part, including a deleted corrupt part on
    /// retry. Zero marks a successful fetch resident; it does not erase its slot.
    /// Parts resident before this session were never charged and stay cost-free.
    package mutating func setCost(_ id: String, to cost: Int64) throws {
        guard var part = parts[id] else { return }
        if cost == 0 {
            if !part.resident {
                residentBytes = try SpaceBudget.adding(residentBytes, part.size)
                part.resident = true
            }
        } else {
            if part.resident { residentBytes -= part.size; part.resident = false }
            if cost != part.size {
                try peak.add(from: part.first, through: external.contains(id) ? count - 1 : part.last,
                    value: cost - part.size)
                part.size = cost
            }
        }
        parts[id] = part
    }

    package mutating func finish(_ file: FileTask) throws {
        finishedDecoded = try SpaceBudget.adding(finishedDecoded, file.size)
        for id in SpaceBudget.references(file) {
            if var part = parts[id], part.resident, part.last == cursor, !external.contains(id) {
                residentBytes -= part.size
                part.resident = false
                parts[id] = part
            }
        }
        cursor += 1
    }

    package func disk(written: Int64 = 0) throws -> Int64 {
        guard cursor < count else { return SpaceBudget.margin }
        let future = try peak.maximum(from: cursor) - finishedDecoded - residentBytes - written
        return try SpaceBudget.adding(max(0, future), SpaceBudget.margin)
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
