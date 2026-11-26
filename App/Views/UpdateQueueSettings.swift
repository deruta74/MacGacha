// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore
import SwiftUI

/// The queue, when it may start work, how quietly it runs, and which games it checks by itself.
/// Reordering works with buttons and the keyboard; dragging is only a shortcut.
struct UpdateQueueSettings: View {
    @Environment(AppModel.self) private var model
    /// Turning the quiet limit back on offers the value it had before.
    @State private var lastQuietLimit: Int64?
    @State private var approving: String?

    var body: some View {
        queueSection
        conditionsSection
        quietSection
        automaticSection
    }

    // MARK: Queue

    private var queueSection: some View {
        Section {
            Toggle("Run update queue", isOn: binding(\.enabled))
            if model.updateQueue.entries.isEmpty {
                Text("The update queue is empty.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.updateQueue.entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                }
            }
        } header: {
            Text("Scheduled Downloads")
        } footer: {
            Text("Add games from their menu, or choose Install Later when you install one. Queued downloads run in order while MacGacha is open, also with its window closed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Install in parts?", isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } })) {
            Button("Install in Parts") {
                if let id = approving { model.retryQueuedUpdate(id, approved: true) }
                approving = nil
            }
        } message: {
            if let id = approving, let name = model.queueEditionDisplayName(id) {
                Text("\(name) can't be played until the install finishes.")
            }
        }
    }

    private func row(_ entry: UpdateQueue.Entry, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.plannedInstall != nil ? "calendar.badge.clock" : "arrow.down.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.queueEditionDisplayName(entry.id) ?? entry.id)
                if let status = status(entry) {
                    Text(verbatim: status.text)
                        .font(.caption)
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if case .approvalRequired = model.queueFailure(for: entry.id) {
                Button("Install in Parts…") { approving = entry.id }
            } else if entry.paused {
                Button("Retry") { model.retryQueuedUpdate(entry.id) }
            }
            HStack(spacing: 2) {
                Button { model.moveQueuedUpdate(entry.id, by: -1) } label: { Label("Move up", systemImage: "chevron.up") }
                    .disabled(index == 0)
                Button { model.moveQueuedUpdate(entry.id, by: 1) } label: { Label("Move down", systemImage: "chevron.down") }
                    .disabled(index == model.updateQueue.entries.count - 1)
                Button { model.removeQueuedUpdate(entry.id) } label: { Label("Remove from queue", systemImage: "xmark") }
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
        }
        .draggable(entry.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, model.updateQueue.entries.contains(where: { $0.id == id }) else { return false }
            model.moveQueuedUpdate(id, before: entry.id)
            return true
        }
    }

    /// Problems first, then why it waits, then when a planned install starts.
    private func status(_ entry: UpdateQueue.Entry) -> (text: String, isProblem: Bool)? {
        if let failure = model.queueFailure(for: entry.id) {
            if case .approvalRequired = failure {
                return (String(localized: "Not enough free space to install in one go."), true)
            }
            return (failure.userMessage, true)
        }
        if entry.paused { return (String(localized: "Paused — retry when ready."), false) }
        if let waiting = model.queueWaiting(for: entry.id) { return (waiting.userMessage, false) }
        if let install = model.scheduledInstall(for: entry.id), !install.isRunning { return (install.title, false) }
        return nil
    }

    // MARK: When to start

    private var conditionsSection: some View {
        Section {
            Toggle("Use a daily time window", isOn: binding(\.scheduled))
            if model.updateQueue.scheduled {
                DatePicker("Start time", selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("End time", selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                if model.updateQueue.startMinute == model.updateQueue.endMinute {
                    Text("Choose different start and end times.").foregroundStyle(.orange)
                }
            }
            Toggle("Require AC power", isOn: binding(\.requiresAC))
            Toggle("Wait until this Mac is idle", isOn: binding(\.requiresIdle))
            if model.updateQueue.requiresIdle || model.updateQueue.automatic || hasPlannedInstall {
                Picker("Idle time", selection: binding(\.idleMinutes)) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }
            // Rows say why each entry waits; this covers automatic checks with an empty queue.
            if model.updateQueue.entries.isEmpty, let waiting = model.updateQueueWaitingReason {
                Label(waiting, systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Hours and idle time only decide when a download starts. A download that has started keeps going when you come back or the hours end.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasPlannedInstall: Bool { model.updateQueue.entries.contains { $0.plannedInstall != nil } }

    // MARK: Quiet

    private var quietSection: some View {
        Section {
            Toggle(model.quietDownloadsLabel, isOn: Binding(get: { model.quietDownloads }, set: { model.setQuietDownloads($0) }))
            Toggle("Limit speed of scheduled downloads", isOn: Binding(
                get: { model.quietDownloadSpeedLimit != nil },
                set: { on in
                    if !on { lastQuietLimit = model.quietDownloadSpeedLimit }
                    setQuietLimit(on ? lastQuietLimit ?? AppModel.defaultDownloadSpeedLimit : nil)
                }
            ))
            if let limit = model.quietDownloadSpeedLimit {
                LabeledContent("Maximum speed") {
                    HStack(spacing: 6) {
                        TextField("Maximum speed", value: Binding(
                            get: { Double(limit) / 1_000_000 },
                            set: { setQuietLimit(AppModel.downloadSpeedLimit(megabytesPerSecond: $0)) }
                        ), format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        Text("MB/s", comment: "Unit after the download speed field: megabytes per second")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(model.keepMacAwakeForScheduledDownloadsLabel, isOn: Binding(
                get: { model.keepMacAwakeForScheduledDownloads },
                set: { model.setKeepMacAwakeForScheduledDownloads($0) }
            ))
            if let hint = model.updateQueueSleepHint {
                Label(hint.userMessage, systemImage: "moon.zzz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text(verbatim: [
                String(localized: "Quiet downloads use fewer threads and the efficiency cores, so the fans stay quiet. Downloads you start yourself run at full speed."),
                String(localized: "MacGacha can keep this Mac awake only while it's connected to power, and can't wake it from sleep."),
                model.scheduledDownloadsSleepExplanation
            ].joined(separator: " "))
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setQuietLimit(_ value: Int64?) {
        do { try model.setQuietDownloadSpeedLimit(value) } catch { model.show(error) }
    }

    // MARK: Automatic checks

    private var automaticSection: some View {
        Section {
            Toggle("Automatically queue game updates", isOn: binding(\.automatic))
            if model.updateQueue.automatic {
                let groups = model.automaticCheckGameGroups
                    .map { group in (group, group.editions.filter(\.isInstalled)) }
                    .filter { !$0.1.isEmpty }
                if groups.isEmpty {
                    Text("Install a game to choose it here.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0.id) { group, editions in
                    if editions.count == 1, let edition = editions.first, group.editions.count == 1 {
                        gameToggle(edition, label: edition.displayName)
                    } else {
                        Text(verbatim: group.displayName)
                        ForEach(editions) { edition in
                            gameToggle(edition, label: edition.displayName).padding(.leading, 16)
                        }
                    }
                }
            }
        } footer: {
            Text("For the chosen games, MacGacha checks HoYoverse's official version information every six hours and queues an update when one comes out. Checks and these updates wait until no game is running and this Mac is idle.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func gameToggle(_ edition: AutomaticCheckGameGroup.Edition, label: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.updateQueue.automaticGames.contains(edition.id) },
            set: { selected in model.saveUpdateQueue { queue in
                if selected { queue.automaticGames.insert(edition.id) } else { queue.automaticGames.remove(edition.id) }
            } }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                if edition.region == .mainlandChina {
                    Text("Mainland China (Beta)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<UpdateQueue, Value>) -> Binding<Value> {
        Binding(get: { model.updateQueue[keyPath: keyPath] }, set: { value in
            model.saveUpdateQueue { $0[keyPath: keyPath] = value }
        })
    }

    private func timeBinding(_ keyPath: WritableKeyPath<UpdateQueue, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = model.updateQueue[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.saveUpdateQueue { $0[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
        })
    }
}
