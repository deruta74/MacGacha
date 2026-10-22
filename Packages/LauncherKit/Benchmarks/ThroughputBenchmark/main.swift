// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization
import LauncherCore
import DownloadEngine

// Opt-in, never a CI timing test. See README.md for real transport controls:
// swift run -c release --package-path Packages/LauncherKit ThroughputBenchmark 4 20
// Arguments: GiB, latency ms, assemblies, transport, sessions, fragment delay us, disk probe.
// Earlier memory-client/FIXED-probe control at 80e0683:
// 4,299,161,600 bytes; 90.611 s; 47.4 decimal MB/s; peak RSS 53.1 MiB.
// Cumulative work seconds: request wait 75.280, hashing/rereads 23.127,
// assembly 10.195, F_FULLFSYNC 25.102, fsync 0.861 (phases overlap).
// Pipelined memory-client/FIXED-probe control: 5.499 s; 781.9 decimal MB/s; 58.7 MiB RSS.
// Staging: 962.2 MB/s; active network window: 1005.1 MB/s. Cumulative work:
// request wait 71.346, hashing 16.647, assembly 19.703, full sync 0.056,
// fsync 0.650 seconds. Assembly includes extent hashing; work overlaps.
// Results are observations, never timing assertions. Identity
// objects isolate transport/assembly costs; 1/2/8-object files and 0.25–4 MiB
// objects approximate the many-small-files shape without shipping game data.
let gib = Int(CommandLine.arguments.dropFirst().first ?? "4") ?? 4
let latency = Int(CommandLine.arguments.dropFirst(2).first ?? "20") ?? 20
let assemblies = CommandLine.arguments.dropFirst(3).first.flatMap(Int.init) ?? PipelineConfiguration.default.assemblies
let sessionCount = Int(CommandLine.arguments.dropFirst(5).first ?? "8") ?? 8
let fragmentDelayUS = Int(CommandLine.arguments.dropFirst(6).first ?? "100") ?? 100
let diskMode = CommandLine.arguments.dropFirst(7).first ?? "system"
let useURLSession = CommandLine.arguments.dropFirst(4).first == "urlsession"
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacGacha-throughput-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let metrics = Metrics()
let sizes = [262_144, 524_288, 1_048_576, 1_048_576, 1_048_576, 2_097_152, 4_194_304, 524_288]
let payloads = sizes.enumerated().map { Data(repeating: UInt8($0.offset + 1), count: $0.element) }
func md5(_ data: Data) -> Digest { var h = StreamingHasher(.md5); h.update(data); return h.finalize() }
let server = try useURLSession ? LoopbackServer(payloads: payloads, latencyMS: latency, fragmentDelayUS: fragmentDelayUS) : nil
defer { server?.stop() }
let baseURL = server.map { "http://127.0.0.1:\($0.port)" } ?? "https://benchmark.invalid"
let digests = payloads.map(md5)
var objects: [String: ChunkObject] = [:], files: [FileTask] = [], transferred: Int64 = 0, index = 0
while transferred < Int64(gib) << 30 {
    let count = files.count % 16 == 15 ? 8 : files.count % 3 == 2 ? 2 : 1
    var extents: [Extent] = [], size: Int64 = 0, h = StreamingHasher(.md5)
    for _ in 0..<count {
        let slot = index % payloads.count, data = payloads[slot], id = String(index)
        let object = ChunkObject(id: id, urls: [URL(string: "\(baseURL)/\(id)")!],
            transferSize: Int64(data.count), transferDigest: digests[slot], decodedSize: Int64(data.count), decodedDigest: digests[slot])
        objects[id] = object
        extents.append(Extent(source: .chunk(id: id), fileOffset: size, length: Int64(data.count), digest: digests[slot]))
        h.update(data); size += Int64(data.count); index += 1
    }
    files.append(FileTask(path: try SafeRelativePath("files/\(files.count)"), size: size, digest: h.finalize(), extents: extents))
    transferred += size
}
let plan = InstallPlan(id: try SafeIdentifier("throughput"), objects: objects, files: files)
let configuration = URLSessionConfiguration.ephemeral
configuration.urlCache = nil; configuration.httpMaximumConnectionsPerHost = SpaceBudget.defaultMaxConcurrentObjects
let transport = URLSessionHTTPClient(configuration: configuration, sessionCount: sessionCount, highWaterMark: 4 << 20, lowWaterMark: 1 << 20).observingDataCallbacks { metrics.callback($0, $1) }
defer { transport.invalidate() }
let http: any HTTPClient = useURLSession ? transport : MemoryHTTP(payloads: payloads, latency: .milliseconds(latency), metrics: metrics)
let fetcher = ChunkFetcher(http: http, retry: RetryPolicy(maxAttempts: 1), sleeper: ContinuousSleeper())
print("transport=\(useURLSession ? "URLSession" : "memory") sessions=\(sessionCount) fragment_delay_us=\(fragmentDelayUS) disk=\(diskMode) pid=\(getpid())")
fflush(nil)
let selectedDisk: any DiskSpaceProbe
switch diskMode {
case "fixed": selectedDisk = FixedDisk()
case "important": selectedDisk = ImportantUsageProbe()
default: selectedDisk = SystemDiskSpaceProbe()
}
let cpu = ThreadCPU()
let clock = ContinuousClock(), start = clock.now
try await OperationWork.$timingObserver.withValue({ metrics.add($0.rawValue, $1) }) {
    var phase = "initialization", phaseStart = ContinuousClock.now
    let engine = try InstallOperation(plan: plan, installRoot: directory, fetcher: fetcher,
        disk: MeasuredDisk(base: selectedDisk, metrics: metrics), fileOps: MeasuredFileOps(metrics: metrics), pipeline: PipelineConfiguration(assemblies: assemblies))
    for try await event in engine.run() {
        if case .phase(let value) = event {
            let next = String(describing: value)
            if phase != next { metrics.add("phase_wall." + phase, phaseStart.duration(to: .now)); phase = next; phaseStart = .now }
        }
    }
}
let elapsed = seconds(start.duration(to: clock.now))
cpu.finish(seconds: elapsed)
var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
print("bytes=\(transferred) objects=\(objects.count) files=\(files.count) latency_ms=\(latency) assemblies=\(assemblies)")
print(String(format: "wall_s=%.3f MB/s=%.1f peak_RSS_MiB=%.1f", elapsed, Double(transferred) / elapsed / 1_000_000, Double(usage.ru_maxrss) / 1_048_576))
if let network = metrics.networkSeconds, let staging = metrics.snapshot["phase_wall.staging"] {
    print(String(format: "network_window_s=%.3f network_MB/s=%.1f staging_s=%.3f staging_MB/s=%.1f", network,
        Double(transferred) / network / 1_000_000, staging, Double(transferred) / staging / 1_000_000))
}
metrics.printCallbacks()
print("cumulative_work_seconds (overlap; assembly includes extent hashing): \(metrics.snapshot)")

func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
final class Metrics: Sendable {
    private struct Callback { var count = 0; var bytes = 0; var seconds: Double = 0 }
    private let callbacks = Mutex<[UInt64: Callback]>([:])
    func callback(_ bytes: Int, _ elapsed: Duration) {
        var id: UInt64 = 0; pthread_threadid_np(nil, &id)
        callbacks.withLock { s in s[id, default: Callback()].count += 1; s[id]!.bytes += bytes; s[id]!.seconds += seconds(elapsed) }
    }
    func printCallbacks() {
        let rows = callbacks.withLock { $0.sorted { $0.value.seconds > $1.value.seconds } }
        print("callback_threads=\(rows.count) callbacks=\(rows.reduce(0) { $0 + $1.value.count }) bytes=\(rows.reduce(0) { $0 + $1.value.bytes })")
        for (id, c) in rows.prefix(8) { print(String(format: "callback_thread=%llu work_s=%.3f calls=%d", id, c.seconds, c.count)) }
    }
    private let values = Mutex<[String: Double]>([:])
    private let network = Mutex<(ContinuousClock.Instant?, ContinuousClock.Instant?)>((nil, nil))
    func add(_ key: String, _ duration: Duration) { values.withLock { $0[key, default: 0] += seconds(duration) } }
    var snapshot: [String: Double] { values.withLock { $0 } }
    func networkStart() { network.withLock { if $0.0 == nil { $0.0 = .now } } }
    func networkEnd() { network.withLock { $0.1 = .now } }
    var networkSeconds: Double? { network.withLock { if let start = $0.0, let end = $0.1 { seconds(start.duration(to: end)) } else { nil } } }
}
struct FixedDisk: DiskSpaceProbe { func availableBytes(at url: URL) throws -> Int64 { Int64.max } }
struct MemoryHTTP: HTTPClient {
    let payloads: [Data]
    let latency: Duration
    let metrics: Metrics
    func get(_ url: URL, byteRangeFrom offset: Int64?) async throws -> (HTTPResponseHead, HTTPBody) {
        metrics.networkStart()
        let start = ContinuousClock.now
        try await Task.sleep(for: latency)
        metrics.add("network_wait", start.duration(to: .now))
        let data = payloads[(Int(url.lastPathComponent) ?? 0) % payloads.count]
        let cursor = Mutex(Int(offset ?? 0))
        return (HTTPResponseHead(status: 200, contentLength: Int64(data.count)), HTTPBody(next: {
            cursor.withLock { cursor in
                guard cursor < data.count else { return nil }
                let end = min(data.count, cursor + 65_536)
                defer { cursor = end }
                if end == data.count { metrics.networkEnd() }
                return data.subdata(in: cursor..<end)
            }
        }))
    }
}
struct MeasuredFileOps: FileOps {
    let metrics: Metrics
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try SystemFileOps().write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws {
        let start = ContinuousClock.now
        defer { metrics.add(durable ? "full_sync" : "fsync", start.duration(to: .now)) }
        try SystemFileOps().synchronize(descriptor, durable: durable)
    }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try SystemFileOps().rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws { try SystemFileOps().unlink(name, in: directory, isDirectory: isDirectory) }
}

/// Retain the former API as an opt-in benchmark control, never production code.
struct ImportantUsageProbe: DiskSpaceProbe {
    func availableBytes(at url: URL) throws -> Int64 {
        // Reproduce the original fresh-URL query. Reusing a URL's resource cache
        // would hide the cost AND can return stale free capacity.
        var ancestor = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path) { ancestor = ancestor.deletingLastPathComponent() }
        let values = try ancestor.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes > 0 { return bytes }
        if let bytes = values.volumeAvailableCapacity, bytes > 0 { return Int64(bytes) }
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }
}
struct MeasuredDisk: DiskSpaceProbe {
    let base: any DiskSpaceProbe
    let metrics: Metrics
    func availableBytes(at url: URL) throws -> Int64 {
        let start = ContinuousClock.now
        defer { metrics.add("capacity_probe", start.duration(to: .now)) }
        return try base.availableBytes(at: url)
    }
}
