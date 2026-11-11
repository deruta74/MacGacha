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
        RuntimeVersionGroup.group(model.rows).filter { $0.category == category }
    }
}

private struct DependencyCard: View {
    @Environment(AppModel.self) private var model
    let group: RuntimeVersionGroup
    @State private var removing: RuntimeRow?

    private var hasCatalog: Bool { model.runtimeCatalog != nil }
    private var status: RuntimeVersionGroup.Status {
        let status = group.status(selected: model.runtimeIsSelected, recommended: model.runtimeIsRecommended, hasCatalog: hasCatalog)
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
            if offersWineChoice {
                Divider().padding(.horizontal, 14)
                WineChoice(group: group, active: active, remove: { removing = $0 })
            } else if showsVersions {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 40) }
                        VersionRow(row: row, isActive: row.id == active?.id, remove: { removing = row })
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
                detail.padding(.top, 2)
            }
            Spacer(minLength: 12)
            actions
        }
    }

    @ViewBuilder private var badge: some View {
        switch status {
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
            Text(DependencyText.download(row)).detailStyle()
        case .ready(let row), .updateAvailable(let row, _):
            // With a version list the checked row already says this. The Wine
            // choice stays collapsed, so the header names what games use.
            if offersWineChoice { ActiveVersionLine(row: row, wineChoice: true) } else if !showsVersions { ActiveVersionLine(row: row) }
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
                ActiveMenu(row: current, offersPin: !offersWineChoice, remove: { removing = current })
            case .damaged:
                EmptyView()
            }
        }
        .controlSize(.regular)
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
                Text(StatusText.joined(using, DependencyText.source(row)))
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
                if case .working = row.state {
                    InstallProgress(row: row, showsVersion: false)
                } else {
                    Text(caption).detailStyle()
                }
            }
            Spacer(minLength: 8)
            if !isActive { trailing }
        }
        .padding(.horizontal, pinsChoice ? 0 : 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var caption: String {
        var parts: [String] = []
        if pinsChoice {
            if isActive {
                let installed = if case .installed = row.state { true } else { false }
                parts.append(installed ? String(localized: "In use") : String(localized: "Selected"))
            }
            if model.runtimeIsRecommended(row.id) { parts.append(String(localized: "Recommended")) }
            if let graphics = DependencyText.graphics(row) { parts.append(graphics) }
            switch row.state {
            case .installed: parts.append(DependencyText.source(row))
            case .notInstalled: if let size = row.downloadSize, size > 0 { parts.append(String(localized: "About \(ByteSize.text(size)) to download")) }
            case .failed(let message): parts.append(message)
            case .invalid(let reason, _): parts.append(String(localized: "Damaged: \(reason)"))
            case .working: break
            }
            return parts.reduce("") { $0.isEmpty ? $1 : StatusText.joined($0, $1) }
        }
        if isActive {
            // A selected version that isn't on disk yet is what Set Up installs, not what games use.
            let installed = if case .installed = row.state { true } else { false }
            let state = installed ? String(localized: "In use") : String(localized: "Selected")
            parts.append(model.runtimeIsPinned(row.id) ? StatusText.joined(state, String(localized: "Pinned")) : state)
        }
        if model.runtimeIsRecommended(row.id) { parts.append(String(localized: "Recommended")) }
        switch row.state {
        case .installed: parts.append(DependencyText.source(row))
        case .notInstalled: parts.append(DependencyText.download(row))
        case .failed(let message): parts.append(message)
        case .invalid(let reason, _): parts.append(String(localized: "Damaged: \(reason)"))
        case .working: break
        }
        return parts.reduce("") { $0.isEmpty ? $1 : StatusText.joined($0, $1) }
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
            if phase != .deleting && phase != .cleaningUp {
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
                    VersionRow(row: row, isActive: !isAutomatic && row.id == active?.id, pinsChoice: true, remove: { remove(row) })
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
        .onAppear { if UserDefaults.standard.bool(forKey: "MacGachaDebugExpanded") { expanded = true } }
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
        if case .notInstalled = recommended.state { return StatusText.joined(now, DependencyText.download(recommended)) }
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

    static func source(_ row: RuntimeRow) -> String {
        if case .installed(.importFromGPTK) = row.state { return String(localized: "Imported from Game Porting Toolkit") }
        return row.licenseName
    }

    static func download(_ row: RuntimeRow) -> String {
        let license = row.needsConsent ? String(localized: "Apple license") : row.licenseName
        guard let size = row.downloadSize, size > 0 else { return license }
        return StatusText.joined(String(localized: "About \(ByteSize.text(size)) to download"), license)
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
        HStack(spacing: 4) {
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
