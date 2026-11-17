import Combine
import CoreGraphics
import CoreImage
import Foundation

@MainActor
final class CoverFlowArtwork: ObservableObject {
    private let images = NSCache<NSURL, CGImage>()
    private var pending: ArraySlice<URL> = []
    private var pinnedURLs = Set<URL>()
    private var pinned: [URL: CGImage] = [:]
    private var inFlight: Set<URL> = []
    private var lastFailure: [URL: Date] = [:]

    init() {
        images.totalCostLimit = 128 * 1024 * 1024
        images.countLimit = 320
    }

    func image(for url: URL?) -> CGImage? {
        guard let url else { return nil }
        return pinned[url] ?? images.object(forKey: url as NSURL)
    }

    static func priorityURLs(in stations: [Source], around index: Int, playingArtwork: URL?) -> [URL] {
        guard stations.indices.contains(index) else { return [] }
        var ordered = [stations[index].artwork, playingArtwork].compactMap { $0 }
        let farthest = max(index, stations.count - 1 - index)
        for distance in 0..<farthest {
            for neighbor in [index - distance - 1, index + distance + 1] where stations.indices.contains(neighbor) {
                if let url = stations[neighbor].artwork { ordered.append(url) }
            }
        }
        var seen = Set<URL>()
        return ordered.filter { seen.insert($0).inserted }
    }

    func prefetch(_ urls: [URL]) {
        let retryBefore = Date().addingTimeInterval(-45)
        pinnedURLs = Set(urls.prefix(25))
        pinned = pinned.filter { pinnedURLs.contains($0.key) }
        for url in pinnedURLs {
            if let cached = images.object(forKey: url as NSURL) { pinned[url] = cached }
        }
        pending = urls.filter { url in
            image(for: url) == nil && !inFlight.contains(url) &&
                (lastFailure[url] ?? .distantPast) < retryBefore
        }[...]
        startLoads()
    }

    private func startLoads() {
        while inFlight.count < 6, let url = pending.popFirst() {
            inFlight.insert(url)
            Task { [weak self] in
                let image = try? await Catalog.artworkThumbnail(from: url, maxPixels: 600, cachePolicy: .returnCacheDataElseLoad)
                guard let self else { return }
                if let image {
                    self.lastFailure.removeValue(forKey: url)
                    self.images.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                    if self.pinnedURLs.contains(url) { self.pinned[url] = image }
                    self.objectWillChange.send()
                } else {
                    self.lastFailure[url] = Date()
                }
                self.inFlight.remove(url)
                self.startLoads()
            }
        }
    }
}

enum CoverHighlight {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ source: CGImage) async -> CGImage? {
        guard !Task.isCancelled,
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return nil }
        let input = CIImage(cgImage: source)
        // Keep shadow and midtone gain close to one, with about 24% headroom at white.
        let curve = CIVector(x: 0, y: 0.92, z: 0, w: 0.32)
        let highlighted = input.applyingFilter("CIColorPolynomial", parameters: [
            "inputRedCoefficients": curve,
            "inputGreenCoefficients": curve,
            "inputBlueCoefficients": curve,
            "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
        ])
        return context.createCGImage(highlighted, from: input.extent, format: .RGBAh, colorSpace: space)
    }
}
