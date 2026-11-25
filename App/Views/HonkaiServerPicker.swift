// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import SwiftUI
import LauncherCore

/// HoYoPlay's server menu for Honkai Impact 3rd. Each server is its own installation,
/// so the menu also says which servers are installed or running.
struct HonkaiServerPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let servers = model.honkaiServers
        let selected = model.selectedHonkaiServer
        Menu {
            ForEach(servers) { entry in
                // A toggle draws the menu's own checkmark for the selected server.
                Toggle(isOn: Binding(get: { entry.server == selected },
                    set: { if $0 { model.selectHonkaiServer(entry.server) } })) {
                    Text(verbatim: entry.description)
                    if let status = status(entry) {
                        Text(verbatim: status)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(verbatim: servers.first { $0.server == selected }?.description ?? selected.englishDescription)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        .foregroundStyle(.white)
        .help(Text("Game server", comment: "Help for the Honkai Impact 3rd server menu"))
        .accessibilityLabel(Text("Game server", comment: "Help for the Honkai Impact 3rd server menu"))
    }

    private func status(_ entry: HonkaiServerState) -> String? {
        switch entry.status {
        case .playing: String(localized: "Playing")
        case .inProgress:
            String(localized: "In progress", comment: "Honkai Impact 3rd server menu: an install, update or check is running for this server")
        case .installed: String(localized: "Installed")
        case nil: nil
        }
    }
}
