// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit

@MainActor extension LauncherAppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model = dockModel else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for game in model.dockGames {
            let item = NSMenuItem(title: game.playTitle, action: #selector(playDockGame(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = game.id
            item.isEnabled = game.canPlay
            menu.addItem(item)
        }
        if let running = model.dockRunningGame {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: running.name, action: nil, keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    @objc private func playDockGame(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        dockModel?.playFromDock(id)
    }
}
