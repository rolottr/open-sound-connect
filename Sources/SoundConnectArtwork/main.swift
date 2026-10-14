import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Build-time tool. Usage:
//   SoundConnectArtwork icon <source.png> <out.iconset>
// Takes the generated graphite/gold tile artwork, finds the opaque tile (ignoring the speckled alpha fringe
// the generator left around it), re-masks it with a clean continuous rounded rectangle on the standard macOS
// 1024 grid (824 pt tile, 100 pt margins), adds the system-style grounding shadow and writes every iconset size.

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8] // RGBA premultiplied

    init(image: CGImage) {
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Alpha at (x, y) with y measured from the top.
    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("Cannot read \(path)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { fail("Cannot finalize \(url.path)") }
}

/// Finds the tile: rows/columns where most pixels are opaque. Speckles never fill a whole row.
func tileBounds(_ bitmap: Bitmap) -> (rect: CGRect, cornerRadius: CGFloat) {
    func opaqueCount(row y: Int) -> Int { (0..<bitmap.width).reduce(0) { $0 + (bitmap.alpha($1, y) > 240 ? 1 : 0) } }
    func opaqueCount(column x: Int) -> Int { (0..<bitmap.height).reduce(0) { $0 + (bitmap.alpha(x, $1) > 240 ? 1 : 0) } }
    let rowThreshold = bitmap.width / 2
    let columnThreshold = bitmap.height / 2
    let rows = (0..<bitmap.height).filter { opaqueCount(row: $0) > rowThreshold }
    let columns = (0..<bitmap.width).filter { opaqueCount(column: $0) > columnThreshold }
    guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else {
        fail("No opaque tile found")
    }
    // Corner radius: how far in from the left edge the first opaque pixel sits on the top tile row.
    let probeRow = top + 1
    var inset = 0
    for x in left..<right where bitmap.alpha(x, probeRow) > 200 {
        inset = x - left
        break
    }
    // For a circular corner, the first opaque pixel one row in is ≈ r - sqrt(2r - 1) from the edge; solve roughly.
    var radius = CGFloat(inset)
    for candidate in stride(from: 4.0, to: Double(right - left) / 2, by: 0.5) {
        let offset = candidate - (2 * candidate - 1).squareRoot()
        if offset >= Double(inset) { radius = CGFloat(candidate); break }
    }
    return (CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1), radius)
}

func renderMaster(source: CGImage) -> CGImage {
    let bitmap = Bitmap(image: source)
    let (tile, sourceRadius) = tileBounds(bitmap)
    let canvas: CGFloat = 1024
    let target = CGRect(x: 100, y: 100, width: 824, height: 824) // Apple icon grid
    // Trim a hair inside the detected tile so no fringe pixels survive the new mask.
    let trim: CGFloat = 2
    let crop = tile.insetBy(dx: trim, dy: trim)
    let scale = target.width / crop.width
    let radius = max(170, min(200, (sourceRadius - trim) * scale))

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let tilePath = CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Grounding shadow, matching the system icon style (soft, slightly below).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.42))
    context.addPath(tilePath)
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // The artwork, re-masked.
    guard let cropped = source.cropping(to: crop) else { fail("Crop failed") }
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.draw(cropped, in: target)
    context.restoreGState()

    // A whisper of top-edge light so the rim reads at small sizes.
    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0.72, alpha: 0.18))
    context.setLineWidth(2)
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count == 4, arguments[1] == "icon" else {
    fail("usage: SoundConnectArtwork icon <source.png> <out.iconset>")
}
let master = renderMaster(source: loadImage(arguments[2]))
let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(resized(master, to: base), to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(resized(master, to: base * 2), to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(master, to: output.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
print("Wrote \(output.path)")
