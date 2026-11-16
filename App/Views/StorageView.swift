// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Launch
import LauncherCore
import SwiftUI

/// Where MacGacha's disk space goes, and what can be removed safely.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: StorageCleanupCandidate?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Form {
            if let snapshot = model.storage {
                Section("Games") {
                    if editions(snapshot).isEmpty {
                        Text("No games installed.").foregroundStyle(.secondary)
                    } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            Text("Game files").gridColumnAlignment(.trailing)
                            Text("Wine prefix").gridColumnAlignment(.trailing)
                            Text("Pre-download").gridColumnAlignment(.trailing)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(editions(snapshot)) { edition in
                            GridRow {
                                Text(Self.gameName(edition.id)).frame(maxWidth: .infinity, alignment: .leading)
                                size(edition.game)
                                size(edition.prefixes)
                                size(edition.preDownload)
                            }
                        }
                    }
                    }
                }
                Section("Shared") {
                    LabeledContent("Wine and graphics layers") { size(snapshot.runtimes) }
                    LabeledContent("Logs") { size(snapshot.logs) }
                    LabeledContent("Art and events") { size(Self.sum(snapshot.artCache, snapshot.eventsCache)) }
                }
                Section {
                    if snapshot.candidates.isEmpty {
                        Text("Nothing to clean up.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.candidates) { candidate in
                        LabeledContent {
                            HStack(spacing: 12) {
                                Text(ByteSize.text(candidate.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button("Remove…") { confirming = candidate }
                                    .disabled(model.storageCleanupInProgress)
                            }
                        } label: {
                            Text(title(candidate))
                            Text(detail(candidate))
                        }
                    }
                } header: {
                    Text("Can be freed")
                } footer: {
                    Text("Game folders, the versions games use and anything a running game or file recovery needs are never listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isRefreshingStorage || model.storageCleanupInProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                }
            }
        }
        .task {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "MacGachaDebugStorage") { return }
            #endif
            await scan()
        }
        .onDisappear { refreshTask?.cancel() }
        .confirmationDialog(confirming.map(title) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming) { candidate in
            Button("Remove \(ByteSize.text(candidate.bytes))", role: .destructive) {
                Task {
                    do { try await model.cleanUp(candidate) }
                    catch { if launcherError(error) != .cancelled { model.show(error) } }
                }
            }
        } message: { candidate in
            Text(detail(candidate))
        }
    }

    /// The walk can take a while on big drives, so a manual refresh replaces the previous one
    /// and closing the panel stops it instead of leaving it running in the background.
    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await scan() }
    }

    private func scan() async {
        do { try await model.refreshStorage() }
        catch { if launcherError(error) != .cancelled { model.show(error) } }
    }

    /// Editions with nothing on disk would only add rows of zeros.
    private func editions(_ snapshot: StorageSnapshot) -> [EditionStorage] {
        snapshot.editions.filter { edition in
            [edition.game, edition.prefixes, edition.preDownload].contains { $0 == .unavailable || ($0.bytes ?? 0) > 0 }
        }
    }

    @ViewBuilder private func size(_ size: StorageSize) -> some View {
        switch size {
        case .available(let bytes):
            Text(bytes > 0 ? ByteSize.text(bytes) : "—").monospacedDigit()
        case .unavailable:
            Text("Drive not connected").foregroundStyle(.secondary)
        }
    }

    private static func sum(_ a: StorageSize, _ b: StorageSize) -> StorageSize {
        guard let x = a.bytes, let y = b.bytes else { return .unavailable }
        return .available(x + y)
    }

    private static func gameName(_ id: String?) -> String {
        guard let id else { return "" }
        return LauncherGame.all.first { $0.id == id }?.name ?? id
    }

    private func title(_ candidate: StorageCleanupCandidate) -> String {
        switch candidate.kind {
        case .orphanedPrefix:
            if let game = candidate.gameID {
                return String(localized: "Old Wine prefix of \(Self.gameName(game))", comment: "Storage cleanup item; the argument is a game name")
            }
            return String(localized: "Unused Wine prefix")
        case .runtimeVersion:
            return model.rows.first { $0.id == candidate.runtimeID }.map { $0.summary ?? "\($0.kindName) \($0.version)" }
                ?? String(localized: "Unused dependency version")
        case .oldSessionLog:
            if let game = candidate.gameID {
                return String(localized: "Older session logs of \(Self.gameName(game))", comment: "Storage cleanup item; the argument is a game name")
            }
            return String(localized: "Older session logs")
        case .inactiveRegionCache:
            return candidate.region == .mainlandChina
                ? String(localized: "Art and events of the Mainland China region")
                : String(localized: "Art and events of the Global region")
        }
    }

    private func detail(_ candidate: StorageCleanupCandidate) -> String {
        switch candidate.kind {
        case .orphanedPrefix:
            String(localized: "No game uses it anymore. Game files and saved logins are elsewhere and stay.")
        case .runtimeVersion:
            String(localized: "No game uses this version and it isn't pinned. You can install it again from Dependencies.")
        case .oldSessionLog:
            String(localized: "The newest log of each game stays for bug reports.")
        case .inactiveRegionCache:
            String(localized: "Downloaded again when you switch to that region.")
        }
    }
}
