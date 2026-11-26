import Combine
import CoreGraphics
import CoreImage
import Foundation

@MainActor
final class CoverFlowArtwork: ObservableObject {
    private static let sharedImages: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 320
        return cache
    }()
    private static var sharedLoads: [URL: Task<CGImage?, Never>] = [:]
    final class StationFace {
        enum Backing {
            case transparent, glass, artwork
        }

        let image: CGImage
        let backing: Backing

        init(image: CGImage, backing: Backing) {
            self.image = image
            self.backing = backing
        }
    }

    private static let stationFaces: NSCache<CGImage, StationFace> = {
        let cache = NSCache<CGImage, StationFace>()
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private var pending: ArraySlice<URL> = []
    private var pinnedURLs = Set<URL>()
    private var pinned: [URL: CGImage] = [:]
    private var inFlight: Set<URL> = []
    private var lastFailure: [URL: Date] = [:]

    static func prepare(_ image: CGImage, for url: URL) {
        guard Catalog.artworkPixels(image) > Catalog.artworkPixels(preparedImage(for: url)) else { return }
        sharedImages.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
    }

    static func preparedImage(for url: URL) -> CGImage? { sharedImages.object(forKey: url as NSURL) }

    static func stationFace(for image: CGImage) -> StationFace {
        if let cached = stationFaces.object(forKey: image) { return cached }
        let isPortrait = image.height - image.width > image.height / 50
        let alpha = stationAlpha(in: image)
        let visibleImage = alpha.bounds.flatMap { image.cropping(to: $0) } ?? image
        let backing: StationFace.Backing = alpha.hasTransparency ? .transparent : (isPortrait ? .glass : .artwork)
        let face = StationFace(image: visibleImage, backing: backing)
        stationFaces.setObject(face, forKey: image, cost: image.bytesPerRow * image.height)
        return face
    }

    private static func stationAlpha(in image: CGImage) -> (hasTransparency: Bool, bounds: CGRect?) {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: break
        default: return (false, nil)
        }
        let size = 96
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return (false, nil) }
        context.clear(bounds)
        context.interpolationQuality = .low
        context.draw(image, in: bounds)
        var transparent = 0
        var left = size, top = size, right = -1, bottom = -1
        for y in 0..<size {
            for x in 0..<size {
                let alpha = pixels[(y * size + x) * 4 + 3]
                if alpha < 240 { transparent += 1 }
                if alpha > 0 {
                    left = min(left, x)
                    right = max(right, x)
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        guard transparent >= 36, left <= right, top <= bottom else { return (false, nil) }
        // Keep a sample of clearance so thin antialiased edges survive the crop.
        let xScale = CGFloat(image.width) / CGFloat(size)
        let yScale = CGFloat(image.height) / CGFloat(size)
        let x = floor(CGFloat(max(0, left - 1)) * xScale)
        let y = floor(CGFloat(max(0, top - 1)) * yScale)
        let maxX = ceil(CGFloat(min(size, right + 2)) * xScale)
        let maxY = ceil(CGFloat(min(size, bottom + 2)) * yScale)
        let crop = CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
        let fullImage = crop.width == CGFloat(image.width) && crop.height == CGFloat(image.height)
        return (true, fullImage ? nil : crop)
    }

    static func load(_ url: URL) async -> CGImage? {
        if let image = preparedImage(for: url) { return image }
        if let pending = sharedLoads[url] { return await pending.value }
        let load = Task {
            let image = await Catalog.bestArtwork(from: url)
            if let image { prepare(image, for: url) }
            sharedLoads.removeValue(forKey: url)
            return preparedImage(for: url) ?? image
        }
        sharedLoads[url] = load
        return await load.value
    }

    func image(for url: URL?) -> CGImage? {
        guard let url else { return nil }
        return Self.preparedImage(for: url) ?? pinned[url]
    }

    static func priorityURLs(in stations: [Source], around index: Int, playingArtwork: URL?) -> [URL] {
        guard stations.indices.contains(index) else { return [] }
        var ordered = [stations[index].stationArtwork, playingArtwork].compactMap { $0 }
        let farthest = max(index, stations.count - 1 - index)
        for distance in 0..<farthest {
            for neighbor in [index - distance - 1, index + distance + 1] where stations.indices.contains(neighbor) {
                if let url = stations[neighbor].stationArtwork { ordered.append(url) }
            }
        }
        var seen = Set<URL>()
        return ordered.filter { seen.insert($0).inserted }
    }

    func prefetch(_ urls: [URL]) {
        let retryBefore = Date().addingTimeInterval(-45)
        pinnedURLs = Set(urls.prefix(16))
        pinned = pinned.filter { pinnedURLs.contains($0.key) }
        for url in pinnedURLs {
            if let cached = Self.preparedImage(for: url) { pinned[url] = cached }
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
                let image = await Self.load(url)
                guard let self else { return }
                if let image {
                    self.lastFailure.removeValue(forKey: url)
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

@MainActor
final class StationArtworkEdgeColors {
    private static let cache: NSCache<CGImage, StationArtworkEdgeColors> = {
        let cache = NSCache<CGImage, StationArtworkEdgeColors>()
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    let top: CGColor?
    let bottom: CGColor?

    private init(image: CGImage) {
        top = Self.sampleRow(in: image, at: 0)
        bottom = Self.sampleRow(in: image, at: image.height - 1)
    }

    static func forLandscapeImage(_ image: CGImage) -> StationArtworkEdgeColors? {
        guard image.width > image.height else { return nil }
        if let cached = cache.object(forKey: image) { return cached }
        let colors = StationArtworkEdgeColors(image: image)
        cache.setObject(colors, forKey: image, cost: image.bytesPerRow * image.height)
        return colors
    }

    private static func sampleRow(in image: CGImage, at y: Int) -> CGColor? {
        let sampleCount = min(image.width, 32)
        guard let row = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: sampleCount, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: sampleCount * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                          CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        context.draw(row, in: CGRect(x: 0, y: 0, width: sampleCount, height: 1))
        let opaqueSamples = (0..<sampleCount).map { $0 * 4 }.filter { pixels[$0 + 3] >= 240 }
        guard opaqueSamples.count > sampleCount / 2 else { return nil }
        // Use the median so lettering or a few stray edge pixels do not tint the fill.
        let rgb = (0..<3).map { channel in
            let values = opaqueSamples.map { CGFloat(pixels[$0 + channel]) / CGFloat(pixels[$0 + 3]) }.sorted()
            return values[values.count / 2]
        }
        return CGColor(colorSpace: space, components: rgb + [1])
    }
}
