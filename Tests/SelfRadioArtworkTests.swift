import AppKit
@main struct Tests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/SelfRadio.png"))
        let image = NSBitmapImageRep(data: data)!
        precondition(image.pixelsWide == 2048 && image.pixelsHigh == 2048)
        for (x,y) in [(0,0),(2047,0),(0,2047),(2047,2047)] {
            let c = image.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
            precondition(c.redComponent == 0 && c.greenComponent == 0 && c.blueComponent == 0 && c.alphaComponent == 1)
        }
        let virtual = Source.selfRadio
        precondition(virtual.isSelfRadio && virtual.isStation && !virtual.isRadio)
        precondition(virtual.fmFrequency == nil)
        let roundTrip = try JSONDecoder().decode(Source.self, from: JSONEncoder().encode(virtual))
        precondition(roundTrip.id == virtual.id && roundTrip.isSelfRadio)
        print("Self Radio virtual-source isolation, persistence, 2048px artwork and pure black corners passed")
    }
}
