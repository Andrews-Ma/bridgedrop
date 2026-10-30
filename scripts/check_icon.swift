import AppKit
import Foundation

@main struct IconChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw NSError(domain: "IconCheck", code: 1) }
        func bitmap(_ path: String) throws -> NSBitmapImageRep {
            guard let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))), image.pixelsWide == 1024, image.pixelsHigh == 1024 else {
                throw NSError(domain: "IconCheck", code: 2)
            }
            return image
        }
        let mac = try bitmap(CommandLine.arguments[1])
        for (x, y) in [(0,0), (1023,0), (0,1023), (1023,1023), (125,125)] {
            guard let color = mac.colorAt(x: x, y: y), color.alphaComponent == 0 else { throw NSError(domain: "IconCheck", code: 3) }
        }
        guard let center = mac.colorAt(x: 512, y: 512), center.alphaComponent > 0.99,
              let top = mac.colorAt(x: 512, y: 150), top.alphaComponent > 0.99 else { throw NSError(domain: "IconCheck", code: 4) }
        let ios = try bitmap(CommandLine.arguments[2])
        guard let corner = ios.colorAt(x: 0, y: 0), corner.alphaComponent > 0.99 else { throw NSError(domain: "IconCheck", code: 5) }
        print("PASS: clean transparent Mac icon corners and an opaque iOS system-mask source")
    }
}
