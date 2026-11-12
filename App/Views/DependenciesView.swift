// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore
import DownloadEngine
import RuntimeManager
import SwiftUI

/// Everything games need besides their own files, one card per dependency.
/// The card leads with what games use now; older and newer versions sit below it.
struct DependenciesView: View {
    @Environment(AppModel.self) private var model
    @State private var category: RuntimeCategory = .runtimes

    var body: some View {
        Group {
            if model.isStarting && model.rows.isEmpty {
                ProgressView("Checking installed dependencies…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(category.explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(groups) { group in
                            DependencyCard(group: group)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .animation(.smooth(duration: 0.2), value: category)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker("Category", selection: $category) {
                        ForEach(RuntimeCategory.allCases, id: \.self) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("Dependencies")
        #if DEBUG
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "MacGachaDebugCategory"), let value = RuntimeCategory(rawValue: name) {
                category = value
            }
        }
        #endif
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshRuntimes() }
                }
                .disabled(model.isStarting || model.runtimeCatalogRefreshing)
                .help("Check installed dependencies and look for updates")
            }
        }
    }

    private var groups: [RuntimeVersionGroup] {
        let groups = RuntimeVersionGroup.group(model.rows).filter { $0.category == category }
        // D3DMetal is what games use by default, so its card leads. The manifest keeps its own
        // order, which carries the bundled recommendation.
        let order = ["bundle-d3dmetal", "bundle-dxmt"]
        return groups.enumerated().sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.element.id) ?? order.count, order.firstIndex(of: b.element.id) ?? order.count)
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }
}

private struct DependencyCard: View {
    @Environment(AppModel.self) private var model
    let group: RuntimeVersionGroup
    @State private var removing: RuntimeRow?

    private var hasCatalog: Bool { model.runtimeCatalog != nil }
    private var autoUpdate: DependencyAutoUpdateState? { model.dependencyAutoUpdate(for: group.id) }
    private var status: RuntimeVersionGroup.Status {
        let status = group.status(selected: model.runtimeIsSelected, recommended: model.runtimeIsRecommended, hasCatalog: hasCatalog)
        // An automatic update works beside the version games use, so the card keeps describing that one.
        switch autoUpdate {
        case .installing, .waitingToActivate, .graphicsUpdateOffered, .graphicsUpdateDeclined:
            if let active, case .installed = active.state { return .ready(active) }
        case .keepingPrevious, nil: break
        }
        // A Wine version the user picked by hand is a choice, not an outdated install.
        if offersWineChoice, case .updateAvailable(let current, _) = status, model.runtimeIsPinned(current.id) { return .ready(current) }
        return status
    }
    /// Runtime bundles for one graphics layer differ by Wine. Wine is chosen
    /// automatically, with tested alternatives behind a disclosure.
    private var offersWineChoice: Bool { hasCatalog && group.rows.count > 1 && group.rows.allSatisfy { $0.backend != nil } }
    private var active: RuntimeRow? { group.active(selected: model.runtimeIsSelected, hasCatalog: hasCatalog) }
    /// One version needs no list: the header already says everything about it.
    private var showsVersions: Bool { group.rows.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)
            if case .ready = status, let offer = graphicsOffer {
                Divider().padding(.horizontal, 14)
                GraphicsUpdateOffer(familyID: group.id, newer: offer.newer, skipped: offer.skipped)
            }
            if offersWineChoice {
                Divider().padding(.horizontal, 14)
                WineChoice(group: group, active: active, remove: { removing = $0 })
            } else if showsVersions {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 40) }
                        VersionRow(row: row, isActive: row.id == active?.id, autoUpdate: autoUpdate, remove: { removing = row })
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await model.remove(removing.id) } }
            }
        } message: {
            Text("Games that use this version won't start until you install it again.")
        }
    }

    private var removalTitle: String {
        guard let removing else { return "" }
        return String(localized: "Remove \(removing.kindName) \(removing.version)?")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            DependencyIcon(familyID: group.id)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.rows[0].kindName).font(.headline)
                            badge
                        }
                        if let about = DependencyIcon.about(group.id) {
                            Text(about)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    actions
                }
                // Below the buttons, so a long version line gets the card's full width.
                detail.padding(.top, 2)
            }
        }
    }

    private var isOffered: Bool { if case .graphicsUpdateOffered = autoUpdate { true } else { false } }
    /// The newer D3DMetal this card asks about. Skipping keeps the row and takes away its emphasis.
    private var graphicsOffer: (newer: RuntimeRow, skipped: Bool)? {
        let (id, skipped): (String, Bool) = switch autoUpdate {
        case .graphicsUpdateOffered(let id): (id, false)
        case .graphicsUpdateDeclined(let id): (id, true)
        default: ("", false)
        }
        return group.rows.first { $0.id == id }.map { ($0, skipped) }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .ready where isOffered: StatusBadge(title: String(localized: "Update available"), tint: .accentColor)
        case .ready: StatusBadge(title: String(localized: "Installed"), tint: .green)
        case .updateAvailable: StatusBadge(title: String(localized: "Update available"), tint: .accentColor)
        case .notInstalled: StatusBadge(title: String(localized: "Not installed"), tint: .secondary)
        case .failed: StatusBadge(title: String(localized: "Failed"), tint: .orange)
        case .damaged: StatusBadge(title: String(localized: "Damaged"), tint: .red)
        case .working: EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        switch status {
        case .working(let row):
            InstallProgress(row: row, showsVersion: showsVersions)
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(TintedIconLabelStyle(tint: .orange))
                .lineLimit(2)
                .textSelection(.enabled)
                .detailStyle()
        case .notInstalled(let row):
            Text(DependencyText.download(row) ?? DependencyText.version(row) ?? "").detailStyle()
        case .ready(let row), .updateAvailable(let row, _):
            // With a version list the checked row already says this. The Wine
            // choice stays collapsed, so the header names what games use.
            VStack(alignment: .leading, spacing: 6) {
                if offersWineChoice { ActiveVersionLine(row: row, wineChoice: true) } else if !showsVersions { ActiveVersionLine(row: row) }
                if let autoUpdate { AutoUpdateNote(state: autoUpdate, group: group, wineChoice: offersWineChoice) }
            }
        case .damaged:
            Text("A copy on disk is damaged. Remove it, then set it up again.").detailStyle()
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch status {
            case .working(let row):
                if case .working(let phase, _) = row.state, phase != .deleting && phase != .cleaningUp {
                    // Removing files and final cleanup always run to the end.
                    Button("Cancel") { model.cancel(row.id) }
                }
            case .notInstalled(let row), .failed(let row, _):
                if row.canImportGPTK {
                    Button("Import…") { model.importGPTK(row.id) }
                        .help("Import D3DMetal from Apple's Game Porting Toolkit")
                }
                SetUpButton(row: row, prominent: true)
            case .updateAvailable(let current, let newer):
                Button("Update") { model.useRuntimeVersion(newer.id) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canUseRuntimeVersion(newer.id))
                    .help(String(localized: "Switch to \(DependencyText.name(newer))"))
                ActiveMenu(row: current, offersPin: !offersWineChoice, remove: { removing = current })
            case .ready(let current):
                switch autoUpdate {
                case .installing(let id) where AutoUpdateNote.canCancel(group, id):
                    Button("Cancel") { model.cancelDependencyAutoUpdate(for: group.id) }
                        .help("Stop this update. Games keep using the current version.")
                default: EmptyView()
                }
                ActiveMenu(row: current, offersPin: !offersWineChoice, remove: { removing = current })
            case .damaged:
                EmptyView()
            }
        }
        .controlSize(.regular)
    }
}

/// One quiet line under the version in use: what an automatic update is doing with this dependency.
private struct AutoUpdateNote: View {
    let state: DependencyAutoUpdateState
    let group: RuntimeVersionGroup
    let wineChoice: Bool

    /// Removing files and final cleanup always run to the end.
    static func canCancel(_ group: RuntimeVersionGroup, _ id: String) -> Bool {
        guard case .working(let phase, _) = group.rows.first(where: { $0.id == id })?.state else { return true }
        return phase != .deleting && phase != .cleaningUp
    }

    private func name(_ id: String) -> String {
        guard let row = group.rows.first(where: { $0.id == id }) else { return id }
        return wineChoice ? DependencyText.wine(row) : DependencyText.name(row)
    }

    var body: some View {
        switch state {
        case .installing(let id):
            let updating = String(localized: "Updating to \(name(id))", comment: "Background dependency update; the argument is the new version")
            let progress: (label: String, fraction: Double?) = if case .working(let phase, let fraction) = group.rows.first(where: { $0.id == id })?.state {
                (StatusText.joined(updating, RuntimePhaseText.label(for: phase, fraction: fraction)), fraction)
            } else { (updating, nil) }
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
                .frame(maxWidth: 260)
                Text(progress.label)
                    .detailStyle()
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progress.label)
        case .waitingToActivate(let id):
            note("\(name(id)) is ready. MacGacha switches to it when no game or download is running.", symbol: "clock")
        case .keepingPrevious(let id):
            if wineChoice {
                note("\(name(id)) will be removed after the first game session on the new version. To keep it, choose it under Wine Version.",
                     symbol: "clock.arrow.circlepath")
            } else {
                note("\(name(id)) will be removed after the first game session on the new version.", symbol: "clock.arrow.circlepath")
            }
        case .graphicsUpdateOffered, .graphicsUpdateDeclined:
            // These get their own row under the header, with the buttons that answer them.
            EmptyView()
        }
    }

    private func note(_ text: LocalizedStringResource, symbol: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol) }
            .labelStyle(TintedIconLabelStyle(tint: .secondary))
            .fixedSize(horizontal: false, vertical: true)
            .detailStyle()
    }
}

/// A newer D3DMetal waits for a yes. Wine updates on its own, but an imported D3DMetal
/// is the user's own copy of Apple's software, so MacGacha asks before replacing it.
/// Skipping is remembered for this D3DMetal version only, and the row stays as the way back.
private struct GraphicsUpdateOffer: View {
    @Environment(AppModel.self) private var model
    let familyID: String
    let newer: RuntimeRow
    let skipped: Bool

    private var name: String { DependencyText.graphics(newer) ?? DependencyText.name(newer) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                text
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    text
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) { buttons }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var text: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(skipped ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if skipped {
                        Text("You skipped \(name)", comment: "Declined dependency update offer; the argument is the skipped version")
                    } else {
                        Text("\(name) is available", comment: "Dependency update offer; the argument is the new version")
                    }
                }
                .font(.callout)
                Group {
                    if skipped {
                        Text("You can still update whenever you like.")
                    } else {
                        Text("You imported D3DMetal yourself, so MacGacha asks first.")
                    }
                }
                .detailStyle()
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var buttons: some View {
        if !skipped {
            Button("Skip This Version") { model.declineGraphicsUpdate(for: familyID) }
                .buttonStyle(.borderless)
                .help("Hide this offer. You can still update from this card later.")
        }
        GraphicsUpdateButtons(newer: newer)
    }
}

/// The normal D3DMetal paths: Apple's download after its terms, or a newer Game Porting Toolkit.
private struct GraphicsUpdateButtons: View {
    @Environment(AppModel.self) private var model
    let newer: RuntimeRow

    var body: some View {
        if newer.canImportGPTK {
            Button("Import…") { model.importGPTK(newer.id) }
                .help("Import D3DMetal from Apple's Game Porting Toolkit")
        }
        Button("Update…") { model.useRuntimeVersion(newer.id) }
            .disabled(!model.canUseRuntimeVersion(newer.id))
            .help(String(localized: "Switch to \(DependencyText.name(newer))"))
    }
}

/// The version games use, with its pin. Pinned versions stay put when a newer one appears.
private struct ActiveVersionLine: View {
    @Environment(AppModel.self) private var model
    let row: RuntimeRow
    var wineChoice = false

    var body: some View {
        let pinned = model.runtimeIsPinned(row.id)
        let using = String(localized: "Using \(DependencyText.name(row))")
        Label {
            if wineChoice {
                Text(StatusText.joined(using, pinned ? String(localized: "Wine chosen by you") : String(localized: "Wine chosen automatically")))
            } else {
                // A helper has no name beyond its version, so the line is the version itself.
                Text(DependencyText.joined((row.summary == nil ? [] : [using]) + DependencyText.installed(row, showsVersion: true)))
            }
        } icon: {
            Image(systemName: pinned ? "pin.fill" : "checkmark.circle.fill")
        }
        .labelStyle(TintedIconLabelStyle(tint: pinned ? .orange : .green))
        .help(pinned ? Text("Pinned. MacGacha keeps this version even when a newer one is recommended.") : Text(verbatim: row.licenseName))
        .detailStyle()
    }
}

/// Secondary actions for the version in use: pinning and removal stay out of the way.
private struct ActiveMenu: View {
    @Environment(AppModel.self) private var model
    let row: RuntimeRow
    var offersPin = true
    let remove: () -> Void

    var body: some View {
        Menu {
            if offersPin && model.runtimeCatalog != nil && model.runtimeIsSelected(row.id) {
                if !model.runtimeIsPinned(row.id) {
                    Button("Keep This Version", systemImage: "pin") { model.useRuntimeVersion(row.id, pinned: true) }
                        .disabled(!model.canUseRuntimeVersion(row.id))
                } else if model.runtimeIsRecommended(row.id) {
                    Button("Unpin", systemImage: "pin.slash") { model.useRuntimeVersion(row.id) }
                        .disabled(!model.canUseRuntimeVersion(row.id))
                }
                Divider()
            }
            Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
                .disabled(!model.canRemoveRuntime(row.id))
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

/// One row per known version, in catalog order. The version in use carries a check mark.
private struct VersionRow: View {
    @Environment(AppModel.self) private var model
    let row: RuntimeRow
    let isActive: Bool
    /// Rows inside the Wine choice name the Wine and pin when used.
    var pinsChoice = false
    var autoUpdate: DependencyAutoUpdateState? = nil
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pinsChoice ? DependencyText.wine(row) : DependencyText.name(row))
                    .font(.callout)
                    .monospacedDigit()
                if case .working(let phase, let fraction) = row.state {
                    if isBackgroundUpdate {
                        // The card header owns this update's progress bar and its Cancel.
                        Text(RuntimePhaseText.label(for: phase, fraction: fraction))
                            .detailStyle()
                            .monospacedDigit()
                    } else {
                        InstallProgress(row: row, showsVersion: false)
                    }
                } else {
                    Text(caption).detailStyle()
                }
            }
            Spacer(minLength: 8)
            if !isActive { trailing }
        }
        .padding(.horizontal, pinsChoice ? 0 : 14)
        .padding(.vertical, 7)
        .help(Text(verbatim: row.licenseName))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var isBackgroundUpdate: Bool { autoUpdate == .installing(id: row.id) }

    private var caption: String {
        var parts: [String] = []
        if pinsChoice {
            if isActive {
                let installed = if case .installed = row.state { true } else { false }
                parts.append(installed ? String(localized: "In use") : String(localized: "Selected"))
            }
            if model.runtimeIsRecommended(row.id) { parts.append(String(localized: "Recommended")) }
            if let autoUpdateNote { parts.append(autoUpdateNote) }
            if let graphics = DependencyText.graphics(row) { parts.append(graphics) }
            switch row.state {
            case .installed: parts += DependencyText.installed(row, showsVersion: true)
            case .notInstalled: parts += [DependencyText.version(row), DependencyText.download(row)].compactMap { $0 }
            case .failed(let message): parts.append(message)
            case .invalid(let reason, _): parts.append(String(localized: "Damaged: \(reason)"))
            case .working: break
            }
            return DependencyText.joined(parts)
        }
        if isActive {
            // A selected version that isn't on disk yet is what Set Up installs, not what games use.
            let installed = if case .installed = row.state { true } else { false }
            let state = installed ? String(localized: "In use") : String(localized: "Selected")
            parts.append(model.runtimeIsPinned(row.id) ? StatusText.joined(state, String(localized: "Pinned")) : state)
        }
        if model.runtimeIsRecommended(row.id) { parts.append(String(localized: "Recommended")) }
        if let autoUpdateNote { parts.append(autoUpdateNote) }
        // These rows are titled by their version already, unless a bundle summary names them.
        switch row.state {
        case .installed: parts += DependencyText.installed(row, showsVersion: row.summary != nil)
        case .notInstalled: parts += [row.summary == nil ? nil : DependencyText.version(row), DependencyText.download(row)].compactMap { $0 }
        case .failed(let message): parts.append(message)
        case .invalid(let reason, _): parts.append(String(localized: "Damaged: \(reason)"))
        case .working: break
        }
        return DependencyText.joined(parts)
    }

    /// Marks the row an automatic update is about, so the list agrees with the header.
    private var autoUpdateNote: String? {
        switch autoUpdate {
        case .waitingToActivate(row.id): String(localized: "Waiting to switch", comment: "An installed dependency version that becomes active once games close")
        case .keepingPrevious(row.id): String(localized: "Kept for now", comment: "A replaced dependency version that is removed after the next game session")
        case .graphicsUpdateDeclined(row.id): String(localized: "Skipped", comment: "A dependency version whose update offer the user declined")
        default: nil
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.state {
        case .installed:
            if model.runtimeCatalog != nil {
                Button("Use") { model.useRuntimeVersion(row.id, pinned: pinsChoice ? true : nil) }
                    .disabled(!model.canUseRuntimeVersion(row.id))
                    .help(String(localized: "Use \(DependencyText.name(row)) for every game"))
            }
            Button("Remove…", systemImage: "trash", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!model.canRemoveRuntime(row.id))
                .help("Remove this version")
        case .notInstalled, .failed:
            if row.canImportGPTK {
                Button("Import…") { model.importGPTK(row.id) }
            }
            SetUpButton(row: row, prominent: false, pinned: pinsChoice ? true : nil)
        case .working(let phase, _):
            if phase != .deleting && phase != .cleaningUp && !isBackgroundUpdate {
                Button("Cancel") { model.cancel(row.id) }
            }
        case .invalid(_, let removable):
            if removable {
                Button("Remove…", systemImage: "trash", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!model.canRemoveRuntime(row.id))
            }
        }
    }
}

/// Wine for one graphics layer. Automatic follows the recommended version; picking
/// one by hand pins it, so a later recommendation doesn't move that game setup.
private struct WineChoice: View {
    @Environment(AppModel.self) private var model
    let group: RuntimeVersionGroup
    let active: RuntimeRow?
    let remove: (RuntimeRow) -> Void
    @State private var expanded = false

    private var recommended: RuntimeRow? { group.rows.first { model.runtimeIsRecommended($0.id) } }
    private var isAutomatic: Bool { active.map { !model.runtimeIsPinned($0.id) } ?? false }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded.animation(.smooth(duration: 0.2))) {
            VStack(spacing: 0) {
                if let recommended {
                    AutomaticWineRow(recommended: recommended, isActive: isAutomatic)
                }
                ForEach(group.rows) { row in
                    Divider().padding(.leading, 26)
                    VersionRow(row: row, isActive: !isAutomatic && row.id == active?.id, pinsChoice: true,
                        autoUpdate: model.dependencyAutoUpdate(for: group.id), remove: { remove(row) })
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Wine Version").font(.callout)
                Spacer()
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        #if DEBUG
        // `-MacGachaDebugExpanded YES` opens every card's list, `dxmt` or `d3dmetal` only that one.
        .onAppear {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "MacGachaDebugExpanded") || defaults.string(forKey: "MacGachaDebugExpanded").map({ "bundle-" + $0 }) == group.id {
                expanded = true
            }
        }
        #endif
    }

    private var summary: String {
        guard let active else { return String(localized: "Automatic", comment: "Wine version choice") }
        return isAutomatic ? String(localized: "Automatic", comment: "Wine version choice") : DependencyText.wine(active)
    }
}

private struct AutomaticWineRow: View {
    @Environment(AppModel.self) private var model
    let recommended: RuntimeRow
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic", comment: "Wine version choice").font(.callout)
                Text(caption).detailStyle()
                if !model.autoUpdateDependencies {
                    Text("Automatic updates are off in Settings.")
                        .detailStyle()
                }
            }
            Spacer(minLength: 8)
            if !isActive {
                let installed = if case .installed = recommended.state { true } else { false }
                Button(installed ? String(localized: "Use") : String(localized: "Set Up…")) {
                    model.useRuntimeVersion(recommended.id, pinned: false)
                }
                .disabled(!model.canUseRuntimeVersion(recommended.id))
                .help("Let MacGacha choose the Wine version tested best with this graphics layer")
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var caption: String {
        let now = String(localized: "The recommended version, now \(DependencyText.wine(recommended))")
        // With updates off, the header's Update button already says what there is to get.
        if model.autoUpdateDependencies, case .notInstalled = recommended.state, let download = DependencyText.download(recommended) {
            return StatusText.joined(now, download)
        }
        return now
    }
}

private struct SetUpButton: View {
    @Environment(AppModel.self) private var model
    let row: RuntimeRow
    let prominent: Bool
    var pinned: Bool? = nil

    var body: some View {
        let retry = if case .failed = row.state { true } else { false }
        let title = model.runtimeCatalog != nil
            ? (retry ? String(localized: "Try Again") : String(localized: "Set Up…"))
            : (retry ? String(localized: "Try Again") : String(localized: "Install"))
        let button = Button(title) {
            if model.runtimeCatalog != nil { model.useRuntimeVersion(row.id, pinned: pinned) } else { model.install(row.id) }
        }
        .disabled(model.runtimeCatalog != nil && !model.canUseRuntimeVersion(row.id))
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
}

private struct InstallProgress: View {
    let row: RuntimeRow
    let showsVersion: Bool

    var body: some View {
        if case .working(let phase, let fraction) = row.state {
            let label = RuntimePhaseText.label(for: phase, fraction: fraction)
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
                .frame(maxWidth: 260)
                Text(showsVersion ? StatusText.joined(label, DependencyText.name(row)) : label)
                    .detailStyle()
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .capsule)
    }
}

/// A rounded tile in the dependency's color, like the icons in System Settings.
private struct DependencyIcon: View {
    let familyID: String

    var body: some View {
        let style = Self.style(familyID)
        Image(systemName: style.symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(style.tint.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private static func style(_ id: String) -> (symbol: String, tint: Color) {
        switch id {
        case "bundle-dxmt", "component-dxmt": ("cube.transparent.fill", .blue)
        case "bundle-d3dmetal", "component-d3dmetal": ("cpu.fill", .purple)
        case "component-wine": ("wineglass.fill", .red)
        case "component-jadeite": ("diamond.fill", .teal)
        case "component-steamShim": ("gamecontroller.fill", .indigo)
        case "component-crypt32Fix": ("checkmark.seal.fill", .orange)
        case "component-surroundAudio": ("hifispeaker.2.fill", .pink)
        case "component-genshinFps": ("speedometer", .red)
        default: ("shippingbox.fill", .gray)
        }
    }

    static func about(_ id: String) -> String? {
        switch id {
        case "bundle-dxmt": String(localized: "Wine with DXMT, which runs DirectX 11 games on Metal.", comment: "Dependency description")
        case "bundle-d3dmetal": String(localized: "Wine with Apple's D3DMetal, which runs DirectX 11 and 12 games on Metal.", comment: "Dependency description")
        case "component-jadeite": String(localized: "Lets Honkai: Star Rail start under Wine. You can turn it off in the game's settings.", comment: "Dependency description")
        case "component-steamShim": String(localized: "Lets Genshin Impact and Zenless Zone Zero start under Wine. You can turn it off in the game's settings.", comment: "Dependency description")
        case "component-crypt32Fix": String(localized: "Fixes a Wine signature check that the Mainland China editions of Genshin Impact and Zenless Zone Zero need.", comment: "Dependency description")
        case "component-surroundAudio": String(localized: "Surround sound with Spatial Audio for Genshin Impact and Zenless Zone Zero, used when you turn it on in a game's settings.", comment: "Dependency description")
        case "component-genshinFps": String(localized: "Raises Genshin Impact's frame-rate limit, used only when you turn it on in the game's settings.", comment: "Dependency description")
        default: nil
        }
    }
}

enum DependencyText {
    /// A bundle names its contents in the summary instead of a bare version.
    static func name(_ row: RuntimeRow) -> String { row.summary ?? row.version }

    /// Catalog summaries read "<Wine> · <graphics>"; without that shape the whole summary stands in.
    static func wine(_ row: RuntimeRow) -> String {
        guard let summary = row.summary, let split = summary.range(of: " · ") else { return name(row) }
        return String(summary[..<split.lowerBound])
    }

    static func graphics(_ row: RuntimeRow) -> String? {
        guard let summary = row.summary, let split = summary.range(of: " · ") else { return nil }
        return String(summary[split.upperBound...])
    }

    static func joined(_ parts: [String]) -> String {
        parts.reduce("") { $0.isEmpty ? $1 : StatusText.joined($0, $1) }
    }

    /// What to say about a version on disk: its build and, for D3DMetal, where it came from.
    /// Licenses stay in the row's tooltip.
    static func installed(_ row: RuntimeRow, showsVersion: Bool) -> [String] {
        var parts = showsVersion ? [version(row)].compactMap { $0 } : []
        if case .installed(.importFromGPTK) = row.state { parts.append(String(localized: "Imported from Game Porting Toolkit")) }
        return parts
    }

    /// "Version 1.0": the build of a bundle's own Wine, or a helper's version. A bundle
    /// without a Wine component of its own is named fully by its summary.
    static func version(_ row: RuntimeRow) -> String? {
        guard let raw = row.backend == nil ? row.version : row.wineVersion else { return nil }
        return String(localized: "Version \(build(raw))", comment: "A dependency's version or build number, e.g. Version 11.0-1")
    }

    /// Catalog versions repeat what the name already says. `11.20-macgacha-1.0` is our build
    /// 1.0 of Wine 11.20, and `11.0-1-crossover` or `11.0-yaagl` end with who built them.
    /// Anything else is shown as it is.
    static func build(_ raw: String) -> String {
        if let ours = raw.range(of: "-macgacha-"), ours.upperBound < raw.endIndex { return String(raw[ours.upperBound...]) }
        for builder in ["-crossover", "-yaagl"] where raw.hasSuffix(builder) && raw.count > builder.count {
            return String(raw.dropLast(builder.count))
        }
        return raw
    }

    /// Apple's payload keeps its consent hint: Set Up asks for the license before downloading.
    static func download(_ row: RuntimeRow) -> String? {
        let consent = row.needsConsent ? String(localized: "Apple license") : nil
        guard let size = row.downloadSize, size > 0 else { return consent }
        let text = String(localized: "About \(ByteSize.text(size)) to download")
        return consent.map { StatusText.joined(text, $0) } ?? text
    }
}

enum RuntimePhaseText {
    static func label(for phase: OperationPhase, fraction: Double?) -> String {
        let percent = fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        switch phase {
        case .checkingSpace: return String(localized: "Checking free space…")
        case .staging:
            guard let percent else { return String(localized: "Downloading") }
            return String(localized: "Downloading \(percent)", comment: "The argument is a percentage, e.g. 42%")
        case .verifying:
            guard let percent else { return String(localized: "Verifying") }
            return String(localized: "Verifying \(percent)", comment: "The argument is a percentage, e.g. 42%")
        case .committing: return String(localized: "Installing…")
        case .deleting, .cleaningUp: return String(localized: "Finishing…")
        case .completed: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        }
    }
}

private extension RuntimeCategory {
    var title: String {
        switch self {
        case .runtimes: String(localized: "Runtimes", comment: "Dependencies category")
        case .compatibility: String(localized: "Compatibility", comment: "Dependencies category")
        case .extras: String(localized: "Extras", comment: "Dependencies category")
        }
    }

    var explanation: String {
        switch self {
        case .runtimes: String(localized: "Each game uses the graphics layer chosen in its settings. MacGacha picks a tested Wine version for it.", comment: "Dependencies category")
        case .compatibility: String(localized: "Small helpers some games need to start.", comment: "Dependencies category")
        case .extras: String(localized: "Optional features. Each is set up only when you turn it on for a game.", comment: "Dependencies category")
        }
    }
}

private extension View {
    func detailStyle() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}

/// Keeps the text secondary while the icon carries the state's color.
private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

#Preview {
    DependenciesView()
        .environment(AppModel.preview())
        .frame(width: 720, height: 520)
}
