// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import Observation

/// Decoded art for the visible game, kept in memory so a slide and its highlights button
/// switch together and never show a background whose image is still loading.
@MainActor @Observable final class ArtImageCache {
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    func image(_ url: URL?) -> NSImage? { url.flatMap { images[$0] } }

    /// Keeps only `urls`, so switching games releases the previous game's images.
    func preload(_ urls: [URL]) {
        let wanted = Set(urls)
        if images.keys.contains(where: { !wanted.contains($0) }) { images = images.filter { wanted.contains($0.key) } }
        loading.formIntersection(wanted)
        for url in wanted where images[url] == nil && !loading.contains(url) {
            loading.insert(url)
            Task {
                let image = await Self.load(url)
                // A load that is no longer wanted is dropped rather than repopulating the cache.
                guard loading.remove(url) != nil, let image else { return }
                images[url] = image
            }
        }
    }

    @concurrent private static func load(_ url: URL) async -> NSImage? {
        NSImage(contentsOf: url)
    }
}
