// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Observation

/// Decoded art for the visible game, kept in memory so a slide and its highlights button
/// switch together and never show a background whose image is still loading.
@MainActor @Observable final class ArtImageCache {
    private(set) var images: [URL: NSImage] = [:]
    /// Images that couldn't be decoded, so their slides can be skipped as HoYoPlay does.
    private(set) var failed: Set<URL> = []
    @ObservationIgnored private var loading: Set<URL> = []

    func image(_ url: URL?) -> NSImage? { url.flatMap { images[$0] } }

    /// Keeps only `urls`, so switching games releases the previous game's images.
    func preload(_ urls: [URL]) {
        let wanted = Set(urls)
        if images.keys.contains(where: { !wanted.contains($0) }) { images = images.filter { wanted.contains($0.key) } }
        loading.formIntersection(wanted)
        if failed.contains(where: { !wanted.contains($0) }) { failed.formIntersection(wanted) }
        for url in wanted where images[url] == nil && !loading.contains(url) && !failed.contains(url) {
            loading.insert(url)
            Task {
                let image = await Self.load(url)
                // A load that is no longer wanted is dropped rather than repopulating the cache.
                guard loading.remove(url) != nil else { return }
                if let image { images[url] = image } else { failed.insert(url) }
            }
        }
    }

    @concurrent private static func load(_ url: URL) async -> NSImage? {
        NSImage(contentsOf: url)
    }
}
