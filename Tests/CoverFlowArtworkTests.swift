import CoreGraphics
import Foundation

@main struct Tests {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/SelfRadio.png")
        guard let decoded = await CoverFlowArtwork.load(url) else { fatalError("Bundled cover must decode") }
        precondition(decoded.width == 1200 && decoded.height == 1200)
        let flow = CoverFlowArtwork()
        let overlay = CoverFlowArtwork()
        guard let lowResolution = try await Catalog.artworkThumbnail(from: url, maxPixels: 100) else { fatalError() }
        CoverFlowArtwork.prepare(lowResolution, for: url)
        precondition(flow.image(for: url) === decoded)
        precondition(overlay.image(for: url) === decoded)
        let stations = (0..<5).map { n in Source(id: String(n), title: "Station \(n)", url: URL(string: "https://example.com/\(n)")!, artwork: URL(string: "https://example.com/\(n).png")) }
        let priority = CoverFlowArtwork.priorityURLs(in: stations, around: 2, playingArtwork: url)
        precondition(priority == [stations[2].artwork!, url, stations[1].artwork!, stations[3].artwork!, stations[0].artwork!, stations[4].artwork!])

        let apple = URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb-60.jpg")!
        precondition(Catalog.artworkURLs(for: apple).map(\.lastPathComponent) == ["1200x1200bb-60.jpg", "600x600bb-60.jpg", "100x100bb-60.jpg"])
        let iheart = URL(string: "https://i.iheart.com/v3/re/assets.brands/test?ops=contain(360,360)&quality=80")!
        precondition(Catalog.artworkURLs(for: iheart).first?.query == nil)
        let hot97 = URL(string: "https://www.hot97.com/wp-content/uploads/test.png?w=180")!
        precondition(Catalog.artworkURLs(for: hot97).first?.query == nil)
        let original = URL(string: "https://proxy.zeno.fm/content/stations/example/image/?u=100")!
        let encoded = Data(original.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let zeno = URL(string: "https://zeno.fm/_ipx/s_224x224/https://images.zeno.fm/\(encoded).webp")!
        precondition(Catalog.artworkURLs(for: zeno) == [original, zeno])
        precondition(Catalog.artworkURLs(for: stations[0].artwork!) == [stations[0].artwork!])

        let square = fixture(width: 64, height: 64, inset: 0)
        let wide = fixture(width: 96, height: 48, inset: 0)
        let portrait = fixture(width: 48, height: 96, inset: 0)
        let transparentPortrait = fixture(width: 48, height: 96, inset: 4)
        let paddedLogo = fixture(width: 96, height: 96, inset: 0, visible: CGRect(x: 11, y: 17, width: 68, height: 21))
        let squareFace = CoverFlowArtwork.stationFace(for: square)
        let wideFace = CoverFlowArtwork.stationFace(for: wide)
        let logoFace = CoverFlowArtwork.stationFace(for: paddedLogo)
        precondition(squareFace.backing == .artwork && squareFace.image === square)
        precondition(wideFace.backing == .artwork && wideFace.image === wide)
        precondition(CoverFlowArtwork.stationFace(for: portrait).backing == .glass)
        precondition(CoverFlowArtwork.stationFace(for: transparentPortrait).backing == .transparent)
        precondition(logoFace.backing == .transparent && (68...72).contains(logoFace.image.width) && (21...25).contains(logoFace.image.height))
        precondition(CoverFlowArtwork.stationFace(for: paddedLogo) === logoFace)
        let probe = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        probe.draw(logoFace.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        precondition(probe.data!.assumingMemoryBound(to: UInt8.self)[3] > 200)
        let bands = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bands.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        bands.fill(CGRect(x: 0, y: 16, width: 64, height: 16))
        bands.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        bands.fill(CGRect(x: 0, y: 0, width: 64, height: 16))
        let colors = StationArtworkEdgeColors.forLandscapeImage(bands.makeImage()!)!
        precondition(colors.top!.components![0] > 0.9)
        precondition(colors.bottom!.components![2] > 0.9)
        precondition(StationArtworkEdgeColors.forLandscapeImage(square) == nil)
        print("Cover quality, transparent-logo classification and cropping, and landscape edge fills passed")
    }

    private static func fixture(width: Int, height: Int, inset: CGFloat, visible: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        context.setFillColor(red: 1, green: 0.6, blue: 0.2, alpha: 1)
        context.fill(visible ?? bounds.insetBy(dx: inset, dy: inset))
        return context.makeImage()!
    }
}
