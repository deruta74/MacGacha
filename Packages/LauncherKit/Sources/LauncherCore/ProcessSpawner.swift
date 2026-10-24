// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation

/// Child output is either a private regular log file or direct /dev/null descriptors.
public enum ProcessOutput: Sendable {
    case file(URL)
    case ownedFile(ProcessOutputFile)
    case discard
}

/// An opaque, retained inode. Only contained exclusive creation can supply it.
public struct ProcessOutputFile: Sendable {
    package let file: ContainedFileSystem.OwnedRegularFile
    package init(file: ContainedFileSystem.OwnedRegularFile) { self.file = file }
}

/// Synchronous file/process I/O: async callers must use BlockingIO.run.
/// Returning an identity transfers child lifecycle/reaping to the session watcher:
/// a handed-off child is never signalled or waited on by the spawner.
/// Dropping the returned identity, cancellation, and parent death do not kill it.
/// If the OS creates a child but identity lookup fails before handoff, the spawner
/// SIGKILLs its process group (falling back to its PID), reaps it, then throws.
public protocol ProcessSpawner: Sendable {
    func spawn(_ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL, output: ProcessOutput) throws -> ProcessIdentity
}

public extension ProcessSpawner {
    func spawn(_ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL, outputFile: URL) throws -> ProcessIdentity {
        try spawn(executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, output: .file(outputFile))
    }
}

public struct SystemProcessSpawner: ProcessSpawner {
    private let readIdentity: @Sendable (Int32) -> ProcessIdentity?
    public init() { readIdentity = { SystemProcessKernel().process(pid: $0)?.processIdentity } }
    init(readIdentity: @escaping @Sendable (Int32) -> ProcessIdentity?) { self.readIdentity = readIdentity }

    public func spawn(_ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL, output: ProcessOutput) throws -> ProcessIdentity {
        let outputURLs: [URL] = if case .file(let url) = output { [url] } else { [] }
        for url in [executable, currentDirectory] + outputURLs {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw LauncherError.unsafePath(url.absoluteString) }
        }
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }), environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
        }) else { throw LauncherError.io("Invalid process arguments or environment") }

        let log: Int32? = switch output {
        case .file(let url): try openProcessLog(url)
        case .ownedFile(let owned): try owned.file.duplicateForSpawning()
        case .discard: nil
        }
        defer { if let log { close(log) } }

        var attributes: posix_spawnattr_t?
        try checkSpawn(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        try checkSpawn(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkSpawn(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try checkSpawn(posix_spawnattr_setpgroup(&attributes, 0))
        // Thread-local masks and process-wide ignored dispositions otherwise
        // survive exec. Give every child normal, independently usable signals.
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for number in 1..<NSIG where number != SIGKILL && number != SIGSTOP {
            sigaddset(&defaults, number)
        }
        try checkSpawn(posix_spawnattr_setsigmask(&attributes, &mask))
        try checkSpawn(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checkSpawn(posix_spawn_file_actions_addchdir(&actions, currentDirectory.path))
        try checkSpawn(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        if let log {
            try checkSpawn(posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO))
            try checkSpawn(posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO))
        } else {
            // /dev/null is intentionally not passed through the regular-file log check.
            try checkSpawn(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0))
            try checkSpawn(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        }
        if let log { try checkSpawn(posix_spawn_file_actions_addclose(&actions, log)) }

        return try withProcessStrings([executable.path] + arguments) { argv in
            try withProcessStrings(environment.keys.sorted().map { $0 + "=" + environment[$0]! }) { envp in
                var pid: pid_t = 0
                // Only the three explicit standard streams survive; none depends
                // on the parent's descriptors or lifetime.
                try checkSpawn(posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp))
                // Even a child that exits immediately retains its kernel identity
                // as a zombie until the watcher reaps it after successful handoff.
                guard let identity = readIdentity(pid) else {
                    discardFailedLaunch(pid)
                    throw LauncherError.io("Cannot read spawned process identity")
                }
                return identity
            }
        }
    }
}

private func discardFailedLaunch(_ pid: Int32) {
    // No identity reached the caller, so there is no watcher to own this child.
    if kill(-pid, SIGKILL) < 0 { _ = kill(pid, SIGKILL) }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR { }
}

private func openProcessLog(_ url: URL) throws -> Int32 {
    // NONBLOCK prevents opening a FIFO from stalling before we can reject it.
    // Parent directories are app-owned session directories. Reject a final
    // symlink atomically; fstat pins the regular file used by the spawn actions.
    let opened = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard opened >= 0 else { throw LauncherError.io("Opening process log: \(String(cString: strerror(errno)))") }
    defer { close(opened) }
    var info = stat()
    guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        throw LauncherError.io("Process log must be a regular file")
    }
    let flags = fcntl(opened, F_GETFL)
    guard flags >= 0, fcntl(opened, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
        throw LauncherError.io("Configuring process log")
    }
    // Keep the source clear of 0/1/2 even when our own standard streams are closed.
    let descriptor = fcntl(opened, F_DUPFD_CLOEXEC, 3)
    guard descriptor >= 0 else { throw LauncherError.io("Duplicating process log") }
    return descriptor
}

private func checkSpawn(_ status: Int32) throws {
    guard status == 0 else { throw LauncherError.processSpawnFailed(errno: status) }
}

private func withProcessStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in pointers { free(pointer) } }
    for string in strings {
        guard let pointer = strdup(string) else { throw LauncherError.io("Cannot allocate process arguments") }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
}
