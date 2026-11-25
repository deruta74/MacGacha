// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore
import SwiftUI

/// Keyboard-operable queue editing; reordering never requires dragging.
struct UpdateQueueSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Toggle("Run update queue", isOn: binding(\.enabled))
            Toggle("Use a daily time window", isOn: binding(\.scheduled))
            if model.updateQueue.scheduled {
                DatePicker("Start time", selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("End time", selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                if model.updateQueue.startMinute == model.updateQueue.endMinute {
                    Text("Choose different start and end times.").foregroundStyle(.secondary)
                }
            }
            Toggle("Require AC power", isOn: binding(\.requiresAC))
            Toggle("Wait until this Mac is idle", isOn: binding(\.requiresIdle))
            if model.updateQueue.requiresIdle || model.updateQueue.automatic {
                Picker("Idle time", selection: binding(\.idleMinutes)) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            }
            Toggle("Automatically queue game updates", isOn: binding(\.automatic))
            if model.updateQueue.automatic {
                ForEach(GameDefinition.all, id: \.id) { game in
                    Toggle(isOn: Binding(
                        get: { model.updateQueue.automaticGames.contains(game.id) },
                        set: { selected in model.saveUpdateQueue { queue in
                            if selected { queue.automaticGames.insert(game.id) }
                            else { queue.automaticGames.remove(game.id) }
                        } }
                    )) { gameLabel(game) }
                    .accessibilityLabel(Text(gameAccessibilityLabel(game)))
                }
            }
            if let reason = model.updateQueueWaitingReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if model.updateQueue.entries.isEmpty {
                Text("The update queue is empty.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.updateQueue.entries.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        if let game = GameDefinition.find(entry.id) { gameLabel(game) }
                        Spacer(minLength: 8)
                        if entry.paused {
                            Button("Retry") { model.retryQueuedUpdate(entry.id) }
                        }
                        Button { model.moveQueuedUpdate(entry.id, by: -1) } label: {
                            Label("Move up", systemImage: "arrow.up")
                        }
                        .disabled(index == 0)
                        Button { model.moveQueuedUpdate(entry.id, by: 1) } label: {
                            Label("Move down", systemImage: "arrow.down")
                        }
                        .disabled(index == model.updateQueue.entries.count - 1)
                        Button { model.removeQueuedUpdate(entry.id) } label: {
                            Label("Remove from queue", systemImage: "xmark")
                        }
                    }
                    .labelStyle(.iconOnly)
                    .draggable(entry.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, model.updateQueue.entries.contains(where: { $0.id == id }) else { return false }
                        model.moveQueuedUpdate(id, before: entry.id)
                        return true
                    }
                    if entry.paused { Text("Paused — retry when ready.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Game update queue")
        } footer: {
            Text("Add installed games from their menu. Updates run in order while MacGacha is open. Automatic checks use official version metadata, only for selected installed games, while this Mac is idle and no game is running. Low Data Mode pauses queued work. A failed or manually paused update waits for Retry.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func gameAccessibilityLabel(_ game: GameDefinition) -> String {
        let name = model.queueEditionDisplayName(game.id) ?? game.defaultInstallDirectoryName
        let region = game.region == .global ? String(localized: "Global") : String(localized: "Mainland China (Beta)")
        return [name, region].joined(separator: ", ")
    }

    private func gameLabel(_ game: GameDefinition) -> some View {
        VStack(alignment: .leading) {
            Text(model.queueEditionDisplayName(game.id) ?? game.defaultInstallDirectoryName)
            Text(game.region == .global ? String(localized: "Global") : String(localized: "Mainland China (Beta)"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

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
