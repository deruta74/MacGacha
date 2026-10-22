// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Synchronization

/// Opt-in benchmark server: real TCP, persistent HTTP/1.1, independent socket
/// workers and request latency. No URLProtocol shortcut or external network.
final class LoopbackServer: Sendable {
    let port: UInt16
    private let listener: Int32
    private let payloads: [Data]
    private let delay: UInt32
    private let fragmentDelay: UInt32
    private struct State { var stopped = false; var sockets = Set<Int32>() }
    private let state = Mutex(State())
    init(payloads: [Data], latencyMS: Int, fragmentDelayUS: Int = 100) throws {
        fragmentDelay = UInt32(max(0, fragmentDelayUS))
        self.payloads = payloads; delay = UInt32(max(0, latencyMS)) * 1000
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socketFD = listener
        let result = withUnsafeMutablePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(socketFD, $0, length) == 0, listen(socketFD, 128) == 0 else { return Int32(-1) }
                return getsockname(socketFD, $0, &length)
            }
        }
        guard result == 0 else { Darwin.close(listener); throw CocoaError(.fileReadUnknown) }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            pthread_setname_np("bench.accept")
            while true {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { return }
                let accepted = state.withLock { s in if s.stopped { return false }; s.sockets.insert(fd); return true }
                guard accepted else { Darwin.close(fd); return }
                var flag: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(fd) }
            }
        }
    }
    func stop() {
        let sockets = state.withLock { s in s.stopped = true; return s.sockets }
        shutdown(listener, SHUT_RDWR); Darwin.close(listener)
        for fd in sockets { shutdown(fd, SHUT_RDWR) }
    }
    private func serve(_ fd: Int32) {
        pthread_setname_np("bench.server")
        defer { state.withLock { _ = $0.sockets.remove(fd) }; Darwin.close(fd) }
        var pending = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let delimiter = Data("\r\n\r\n".utf8)
        while true {
            while pending.range(of: delimiter) == nil {
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0, pending.count + n <= 16384 else { return }
                pending.append(contentsOf: buffer.prefix(n))
            }
            let end = pending.distance(from: pending.startIndex, to: pending.range(of: delimiter)!.upperBound)
            let header = String(decoding: pending.prefix(end), as: UTF8.self)
            pending.removeFirst(end)
            let lines = header.components(separatedBy: "\r\n")
            let id = Int(lines[0].split(separator: " ")[1].dropFirst()) ?? 0
            let data = payloads[id % payloads.count]
            let range = lines.first { $0.lowercased().hasPrefix("range: bytes=") }
            let offset = range.flatMap { Int($0.split(separator: "=").last!.split(separator: "-")[0]) } ?? 0
            guard offset >= 0, offset < data.count else { return }
            if delay > 0 { usleep(delay) }
            let status = range == nil ? "200 OK" : "206 Partial Content"
            let contentRange = range == nil ? "" : "Content-Range: bytes \(offset)-\(data.count - 1)/\(data.count)\r\n"
            guard sendAll(Data("HTTP/1.1 \(status)\r\nContent-Length: \(data.count - offset)\r\n\(contentRange)Connection: keep-alive\r\n\r\n".utf8), fd, 0),
                sendAll(data, fd, offset) else { return }
        }
    }
    private func sendAll(_ data: Data, _ fd: Int32, _ offset: Int) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = offset
            while offset < bytes.count {
                let n = send(fd, bytes.baseAddress!.advanced(by: offset), min(fragmentDelay > 0 ? 16384 : 262144, bytes.count - offset), 0)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }; offset += n
                if fragmentDelay > 0, data.count > 16384 { usleep(fragmentDelay) }
            }
            return true
        }
    }
}

/// Sample actual Mach per-thread user+system CPU, including URLSession's native
/// threads. CPU percentages are relative to one core, not the whole machine.
final class ThreadCPU: Sendable {
    private struct State { var previous: [UInt64: Double] = [:]; var totals: [UInt64: Double] = [:]; var names: [UInt64: String] = [:]; var previousTime: [UInt64: ContinuousClock.Instant] = [:]; var peak: [UInt64: Double] = [:] }
    private let state = Mutex(State())
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "bench.cpu"))
    init() {
        capture()
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.capture() }
        timer.resume()
    }
    func finish(seconds: Double) {
        timer.cancel(); capture()
        let rows = state.withLock { s in s.totals.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, s.names[$0.key] ?? "?", $0.value, s.peak[$0.key] ?? 0) } }
        for (id, name, cpu, peak) in rows { print(String(format: "thread=%llu name=%@ CPU_s=%.3f avg_one_core_pct=%.1f peak_100ms_pct=%.1f", id, name, cpu, cpu / seconds * 100, peak)) }
    }
    private func capture() {
        var list: thread_act_array_t?, count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)) }
        for i in 0..<Int(count) {
            let thread = list[i]; defer { mach_port_deallocate(mach_task_self_, thread) }
            var info = thread_basic_info_data_t(), n = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &n) } }
            guard result == KERN_SUCCESS else { continue }
            var idInfo = thread_identifier_info_data_t(), idCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
            let idResult = withUnsafeMutablePointer(to: &idInfo) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(idCount)) { thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &idCount) } }
            guard idResult == KERN_SUCCESS else { continue }
            let cpu = Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
            var name = [CChar](repeating: 0, count: 128)
            if let pthread = pthread_from_mach_thread_np(thread) { pthread_getname_np(pthread, &name, name.count) }
            let label = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            state.withLock { s in
                let delta = max(0, cpu - (s.previous[idInfo.thread_id] ?? cpu)), now = ContinuousClock.now
                if let previous = s.previousTime[idInfo.thread_id] {
                    let elapsed = seconds(previous.duration(to: now))
                    if elapsed > 0 { s.peak[idInfo.thread_id] = max(s.peak[idInfo.thread_id] ?? 0, min(100, delta / elapsed * 100)) }
                }
                s.previousTime[idInfo.thread_id] = now
                s.totals[idInfo.thread_id, default: 0] += delta
                s.previous[idInfo.thread_id] = cpu; s.names[idInfo.thread_id] = label
            }
        }
    }
}
