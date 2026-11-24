import CoreGraphics
import Foundation

@main struct Tests {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/SelfRadio.png")
        guard let decoded = try await Catalog.artworkThumbnail(from: url, maxPixels: 1200) else { fatalError("Bundled cover must decode") }
        precondition(decoded.width == 1200 && decoded.height == 1200)
        let flow = CoverFlowArtwork()
        let overlay = CoverFlowArtwork()
        CoverFlowArtwork.prepare(decoded, for: url)
        precondition(flow.image(for: url) === decoded)
        precondition(overlay.image(for: url) === decoded)
        let stations = (0..<5).map { n in Source(id: String(n), title: "Station \(n)", url: URL(string: "https://example.com/\(n)")!, artwork: URL(string: "https://example.com/\(n).png")) }
        let priority = CoverFlowArtwork.priorityURLs(in: stations, around: 2, playingArtwork: url)
        precondition(priority == [stations[2].artwork!, url, stations[1].artwork!, stations[3].artwork!, stations[0].artwork!, stations[4].artwork!])
        print("Local 1200px cover decoding, shared prepared-artwork availability and center-out preload order passed")
    }
}
