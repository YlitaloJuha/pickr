#!/usr/bin/env swift
// Regenerates test-photos/: 40 synthetic JPEGs in 10 moments, for the simulator
// (`xcrun simctl addmedia booted test-photos/*.jpg`) and the timeline fixture in
// PickrKit/Sources/PickrTestSupport/Fixtures.swift.
//
// Each image is a simple flat illustration (`makeScene`: a sunset with a sailboat, a beach,
// the ocean, a city at night, a garden, flowers, snow, food, a cat, a portrait), one scene per
// moment, each photo a slightly shifted frame of a burst. No camera data and no location: the
// only metadata is the capture time
// (EXIF DateTimeOriginal and DateTimeDigitized, no time zone, so iOS reads it as local time).
// Output is deterministic: the same script writes the same bytes on the same macOS.
//
//   swift scripts/make-test-photos.swift                 writes ./test-photos
//   swift scripts/make-test-photos.swift <dir>           writes <dir>
//   swift scripts/make-test-photos.swift --check <dir>   compares names, sizes and capture times
//
// The v1 originals were flat colours from an earlier, unpublished script; these replace them.
// Names, dimensions and capture times match, so the fixture timeline is unchanged.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - The timeline (the contract with Fixtures.swift)

struct Photo {
    let width: Int
    let height: Int
    let rgb: (UInt8, UInt8, UInt8)
}

struct MomentSpec {
    let name: String
    let start: String           // "HH:mm:ss" on `day`; photos inside a moment are 3 s apart
    let photos: [Photo]
}

let day = "2026:04:12"
let step = 3
let landscape = (640, 480), portrait = (480, 640)

func p(_ size: (Int, Int), _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Photo {
    Photo(width: size.0, height: size.1, rgb: (r, g, b))
}

// Gaps between moments: 93, 123, 48, 183, 23, 153, 38, 203 and 63 s.
// So 10 s gives 10 moments, 30 s gives 9, 60 s gives 7, 180 s gives 3 and 240 s gives 1.
let moments: [MomentSpec] = [
    MomentSpec(name: "beach", start: "09:37:18", photos: [
        p(landscape, 60, 150, 200), p(portrait, 55, 145, 205), p(landscape, 65, 155, 195)]),
    MomentSpec(name: "sunset", start: "09:38:57", photos: [
        p(landscape, 220, 120, 60), p(portrait, 225, 115, 55), p(landscape, 218, 125, 65),
        p(portrait, 230, 110, 50), p(landscape, 215, 130, 70)]),
    MomentSpec(name: "garden", start: "09:41:12", photos: [
        p(landscape, 80, 180, 90), p(portrait, 75, 185, 85), p(landscape, 85, 175, 95),
        p(portrait, 70, 190, 80)]),
    MomentSpec(name: "portrait", start: "09:42:09", photos: [
        p(landscape, 200, 170, 150), p(portrait, 195, 175, 145), p(landscape, 205, 165, 155)]),
    MomentSpec(name: "food", start: "09:45:18", photos: [
        p(landscape, 210, 190, 80), p(portrait, 215, 185, 75), p(landscape, 205, 195, 85),
        p(portrait, 220, 180, 70), p(landscape, 200, 188, 90), p(landscape, 212, 182, 78)]),
    MomentSpec(name: "ocean", start: "09:45:56", photos: [
        p(landscape, 50, 130, 210), p(portrait, 55, 125, 215), p(landscape, 45, 135, 205),
        p(portrait, 60, 120, 220)]),
    MomentSpec(name: "city", start: "09:48:38", photos: [
        p(landscape, 140, 140, 150), p(portrait, 135, 145, 145), p(landscape, 145, 135, 155)]),
    MomentSpec(name: "pet", start: "09:49:22", photos: [
        p(landscape, 170, 140, 100), p(portrait, 175, 135, 95), p(landscape, 165, 145, 105),
        p(portrait, 180, 130, 90), p(landscape, 168, 142, 98)]),
    MomentSpec(name: "flowers", start: "09:52:57", photos: [
        p(landscape, 200, 80, 120), p(portrait, 205, 75, 115), p(landscape, 195, 85, 125),
        p(portrait, 210, 70, 110)]),
    MomentSpec(name: "snow", start: "09:54:09", photos: [
        p(landscape, 210, 220, 230), p(portrait, 215, 215, 225), p(landscape, 205, 225, 235)]),
]

struct Planned {
    let fileName: String
    let exifDate: String        // "yyyy:MM:dd HH:mm:ss"
    let photo: Photo
}

func seconds(_ hms: String) -> Int {
    let parts = hms.split(separator: ":").map { Int($0)! }
    return parts[0] * 3600 + parts[1] * 60 + parts[2]
}

func hms(_ total: Int) -> String {
    String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}

let plan: [Planned] = moments.flatMap { m in
    m.photos.enumerated().map { i, photo in
        Planned(fileName: "\(m.name)_\(i + 1).jpg",
                exifDate: "\(day) \(hms(seconds(m.start) + i * step))",
                photo: photo)
    }
}

// MARK: - Pixels

/// SplitMix64, so the texture noise is the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func fnv1a(_ s: String) -> UInt64 {
    s.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
}

// MARK: - Scenes

/// Flat illustrations in the style of the README banner: one scene per moment, and each photo
/// of a moment is the same scene shifted a little, like a burst.
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func makeScene(_ name: String, index: Int, photo: Photo, seed: UInt64) -> CGImage {
    let w = CGFloat(photo.width), h = CGFloat(photo.height)
    let ctx = CGContext(data: nil, width: photo.width, height: photo.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Top-left origin, like a drawing.
    ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
    var rng = SeededGenerator(state: seed)
    let jitter = { (r: CGFloat) -> CGFloat in CGFloat(Int(rng.next() % 1000)) / 1000 * r * 2 - r }
    let shift = CGFloat(index) * 0.035          // the burst: things drift a little per shot
    func gradient(_ top: CGColor, _ bottom: CGColor, _ y0: CGFloat, _ y1: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: y0, width: w, height: y1 - y0))
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        ctx.restoreGState()
    }
    func rect(_ c: CGColor, _ r: CGRect) { ctx.setFillColor(c); ctx.fill(r) }
    func circle(_ c: CGColor, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    func poly(_ c: CGColor, _ pts: [CGPoint]) {
        ctx.setFillColor(c); ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath(); ctx.fillPath()
    }
    func boat(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) {
        poly(rgb(250, 250, 250), [CGPoint(x: x, y: y - 1.6 * s), CGPoint(x: x, y: y - 0.1 * s), CGPoint(x: x + 0.9 * s, y: y - 0.1 * s)])
        poly(rgb(28, 40, 70), [CGPoint(x: x - 0.7 * s, y: y), CGPoint(x: x + 1.1 * s, y: y), CGPoint(x: x + 0.8 * s, y: y + 0.35 * s), CGPoint(x: x - 0.45 * s, y: y + 0.35 * s)])
    }
    let m = min(w, h)
    switch name {
    case "sunset":
        gradient(rgb(240, 160, 110), rgb(250, 205, 150), 0, h * 0.64)
        circle(rgb(255, 238, 205), w * (0.35 + shift * 0.4), h * (0.40 + shift * 0.3), m * 0.11)
        gradient(rgb(52, 74, 118), rgb(36, 52, 92), h * 0.64, h)
        rect(rgb(80, 100, 145, 0.6), CGRect(x: 0, y: h * 0.64, width: w, height: h * 0.012))
        boat(w * (0.60 + shift + jitter(0.01)), h * 0.66, m * 0.07)
    case "beach":
        gradient(rgb(120, 190, 240), rgb(190, 228, 250), 0, h * 0.55)
        circle(rgb(255, 245, 200), w * 0.78, h * 0.18, m * 0.08)
        gradient(rgb(40, 140, 200), rgb(70, 170, 215), h * 0.55, h * 0.70)
        gradient(rgb(240, 215, 165), rgb(228, 196, 140), h * 0.70, h)
        let ux = w * (0.30 + shift)
        rect(rgb(120, 90, 60), CGRect(x: ux - 2, y: h * 0.62, width: 4, height: h * 0.22))
        poly(rgb(235, 90, 80), [CGPoint(x: ux - m * 0.14, y: h * 0.64), CGPoint(x: ux, y: h * 0.55), CGPoint(x: ux + m * 0.14, y: h * 0.64)])
    case "ocean":
        gradient(rgb(100, 165, 230), rgb(175, 215, 245), 0, h * 0.5)
        circle(rgb(255, 250, 225), w * (0.25 + shift * 0.3), h * 0.22, m * 0.09)
        gradient(rgb(35, 105, 180), rgb(22, 70, 140), h * 0.5, h)
        for k in 0..<5 { rect(rgb(255, 255, 255, 0.25), CGRect(x: w * (0.1 + 0.17 * CGFloat(k)) + w * shift, y: h * (0.6 + 0.07 * CGFloat(k % 3)), width: w * 0.12, height: 3)) }
        boat(w * (0.68 - shift), h * 0.52, m * 0.08)
    case "city":
        gradient(rgb(28, 30, 70), rgb(70, 60, 120), 0, h)
        circle(rgb(245, 235, 200), w * (0.78 - shift * 0.3), h * 0.16, m * 0.06)
        var x: CGFloat = -w * shift * 0.5
        var b = 0
        while x < w {
            let bw = w * (0.10 + 0.04 * CGFloat(b % 3)), bh = h * (0.30 + 0.12 * CGFloat((b * 7) % 4))
            rect(rgb(20, 22, 50), CGRect(x: x, y: h - bh, width: bw - 3, height: bh))
            var wy = h - bh + 10
            while wy < h - 10 { var wx = x + 6; while wx < x + bw - 12 { if (Int(wx + wy) / 7) % 3 != 0 { rect(rgb(250, 210, 120), CGRect(x: wx, y: wy, width: 5, height: 7)) }; wx += 12 }; wy += 16 }
            x += bw; b += 1
        }
    case "garden":
        gradient(rgb(150, 205, 245), rgb(210, 235, 250), 0, h * 0.6)
        circle(rgb(255, 240, 190), w * 0.2, h * 0.2, m * 0.07)
        circle(rgb(120, 190, 100), w * (0.25 + shift), h * 1.05, w * 0.55)
        circle(rgb(90, 165, 85), w * (0.85 - shift), h * 1.1, w * 0.6)
        for k in 0..<3 { let tx = w * (0.2 + 0.3 * CGFloat(k)) + w * shift; rect(rgb(110, 80, 55), CGRect(x: tx - 4, y: h * 0.55, width: 8, height: h * 0.15)); circle(rgb(60, 140, 75), tx, h * 0.52, m * 0.09) }
    case "flowers":
        gradient(rgb(185, 225, 160), rgb(120, 180, 110), 0, h)
        for k in 0..<9 { let fx = w * (0.1 + 0.11 * CGFloat(k)) + w * shift * (k % 2 == 0 ? 1 : -1); let fy = h * (0.3 + 0.18 * CGFloat(k % 3))
            for a in 0..<5 { let t = CGFloat(a) / 5 * 2 * .pi; circle(rgb(235, 110, 150), fx + cos(t) * m * 0.04, fy + sin(t) * m * 0.04, m * 0.03) }
            circle(rgb(255, 215, 90), fx, fy, m * 0.022) }
    case "snow":
        gradient(rgb(190, 215, 240), rgb(230, 240, 250), 0, h * 0.6)
        circle(rgb(250, 250, 255), w * (0.3 + shift), h * 1.0, w * 0.6)
        circle(rgb(240, 245, 252), w * (0.9 - shift), h * 1.05, w * 0.55)
        for k in 0..<4 { let tx = w * (0.15 + 0.22 * CGFloat(k)) + w * shift; poly(rgb(50, 105, 90), [CGPoint(x: tx, y: h * 0.45), CGPoint(x: tx - m * 0.07, y: h * 0.68), CGPoint(x: tx + m * 0.07, y: h * 0.68)]) }
    case "food":
        rect(rgb(235, 205, 160), CGRect(x: 0, y: 0, width: w, height: h))
        circle(rgb(250, 250, 248), w * (0.5 + shift * 0.5), h * 0.5, m * 0.36)
        circle(rgb(240, 238, 232), w * (0.5 + shift * 0.5), h * 0.5, m * 0.28)
        circle(rgb(225, 95, 70), w * (0.45 + shift * 0.5), h * 0.46, m * 0.09)
        circle(rgb(110, 170, 80), w * (0.56 + shift * 0.5), h * 0.55, m * 0.07)
        circle(rgb(245, 200, 80), w * (0.55 + shift * 0.5), h * 0.42, m * 0.06)
    case "pet":
        gradient(rgb(245, 225, 200), rgb(230, 200, 170), 0, h)
        let cx = w * (0.5 + shift * 0.6), cy = h * 0.55
        poly(rgb(60, 55, 60), [CGPoint(x: cx - m * 0.2, y: cy - m * 0.12), CGPoint(x: cx - m * 0.17, y: cy - m * 0.36), CGPoint(x: cx - m * 0.04, y: cy - m * 0.2)])
        poly(rgb(60, 55, 60), [CGPoint(x: cx + m * 0.2, y: cy - m * 0.12), CGPoint(x: cx + m * 0.17, y: cy - m * 0.36), CGPoint(x: cx + m * 0.04, y: cy - m * 0.2)])
        circle(rgb(60, 55, 60), cx, cy, m * 0.22)
        circle(rgb(240, 220, 120), cx - m * 0.08, cy - m * 0.03, m * 0.035); circle(rgb(240, 220, 120), cx + m * 0.08, cy - m * 0.03, m * 0.035)
        circle(rgb(235, 150, 150), cx, cy + m * 0.06, m * 0.02)
    default: // portrait
        gradient(rgb(215, 200, 235), rgb(190, 175, 220), 0, h)
        let cx = w * (0.5 + shift * 0.5)
        circle(rgb(80, 70, 120), cx, h * 1.02, m * 0.38)
        circle(rgb(235, 195, 165), cx, h * 0.45, m * 0.16)
        rect(rgb(70, 50, 40), CGRect(x: cx - m * 0.17, y: h * 0.45 - m * 0.18, width: m * 0.34, height: m * 0.1))
    }
    return ctx.makeImage()!
}

func writeJPEG(_ image: CGImage, exifDate: String, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.92,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: exifDate,
            kCGImagePropertyExifDateTimeDigitized: exifDate,
        ],
    ]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

// MARK: - Check mode

func check(_ dir: URL) -> Bool {
    let fm = FileManager.default
    let expected = Set(plan.map(\.fileName))
    let actual = Set(((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jpg") })
    var ok = true
    for extra in actual.subtracting(expected).sorted() { print("unexpected file: \(extra)"); ok = false }
    for item in plan {
        let url = dir.appendingPathComponent(item.fileName)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            print("missing or unreadable: \(item.fileName)"); ok = false; continue
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
        let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String
        var problems: [String] = []
        if w != item.photo.width || h != item.photo.height {
            problems.append("size \(w ?? 0)x\(h ?? 0), expected \(item.photo.width)x\(item.photo.height)")
        }
        if original != item.exifDate { problems.append("DateTimeOriginal \(original ?? "nil"), expected \(item.exifDate)") }
        if digitized != item.exifDate { problems.append("DateTimeDigitized \(digitized ?? "nil"), expected \(item.exifDate)") }
        if props[kCGImagePropertyGPSDictionary] != nil { problems.append("has GPS data") }
        if !problems.isEmpty { print("\(item.fileName): " + problems.joined(separator: "; ")); ok = false }
    }
    print(ok ? "OK: \(plan.count) photos match the timeline" : "MISMATCH")
    return ok
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--check" {
    exit(check(URL(fileURLWithPath: args.count > 1 ? args[1] : "test-photos")) ? 0 : 1)
}
if args.first == "-h" || args.first == "--help" {
    print("usage: swift scripts/make-test-photos.swift [output-dir] | --check [dir]")
    exit(0)
}

let outDir = URL(fileURLWithPath: args.first ?? "test-photos")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for item in plan {
    let parts = item.fileName.dropLast(4).split(separator: "_")
    let image = makeScene(String(parts[0]), index: Int(parts[1])! - 1, photo: item.photo, seed: fnv1a(item.fileName))
    try writeJPEG(image, exifDate: item.exifDate, to: outDir.appendingPathComponent(item.fileName))
}
print("Wrote \(plan.count) photos in \(moments.count) moments to \(outDir.path)")
