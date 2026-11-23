// Puts each screenshot in images/screens/ into an iPhone frame (black bezel, rounded corners,
// transparent background) and writes images/screens/framed/<name>.png.
//
//   swift scripts/frame-screens.swift [images/screens]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "images/screens")
let out = dir.appending(path: "framed", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func color(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
for file in files {
    guard let shot = load(file) else { continue }
    let sw = CGFloat(shot.width), sh = CGFloat(shot.height)
    let bezel = (sw * 0.038).rounded(), rim = max(2, (sw * 0.006).rounded())
    let screenRadius = sw * 0.135, bodyRadius = screenRadius + bezel
    let w = Int(sw + 2 * bezel), h = Int(sh + 2 * bezel)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let body = CGRect(x: 0, y: 0, width: w, height: h)
    // Outer rim (titanium edge), then the black bezel.
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
    ctx.setFillColor(color(150, 150, 156)); ctx.fillPath()
    let inner = body.insetBy(dx: rim, dy: rim)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: bodyRadius - rim, cornerHeight: bodyRadius - rim, transform: nil))
    ctx.setFillColor(color(18, 18, 20)); ctx.fillPath()
    // The screen.
    let screen = CGRect(x: bezel, y: bezel, width: sw, height: sh)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
    ctx.clip()
    ctx.draw(shot, in: screen)
    ctx.restoreGState()
    // 440 px wide: sharp at the README's 220 pt on Retina screens, small on disk.
    var framed = ctx.makeImage()!
    if framed.width > 440 {
        let scale = 440 / CGFloat(framed.width)
        let sw2 = 440, sh2 = Int((CGFloat(framed.height) * scale).rounded())
        let small = CGContext(data: nil, width: sw2, height: sh2, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        small.interpolationQuality = .high
        small.draw(framed, in: CGRect(x: 0, y: 0, width: sw2, height: sh2))
        framed = small.makeImage()!
    }
    let dest = out.appending(path: file.lastPathComponent)
    let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, framed, nil)
    CGImageDestinationFinalize(d)
    print("framed \(dest.path)")
}
