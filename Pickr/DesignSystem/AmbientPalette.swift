import Foundation

// Pure colour math for ambient backgrounds (blueprint §3.5). Foundation only: no SwiftUI,
// UIKit or Core Graphics types, so every function here can be unit-tested anywhere.
// `AmbientColor.swift` turns the results into views.
//
//   AmbientPalette.averageColor(rgba:)          a few pixels' arithmetic, not ML
//   AmbientPalette.photoTint                     the colour laid over a blurred photo
//   AmbientPalette.photoComposite / composite    what one photo pixel becomes on screen
//   AmbientPalette.contrastRatio(_:_:)           WCAG 2 contrast, for tests and previews
//
// Legibility. Large titles, section headers and empty states sit directly on the blurred
// photos, so the treatment must hold for any photo: over the backdrop (saturation 0.8) lies the
// tint, the photo's average colour tamed (saturation ≤ 0.45, lightness mapped into 0.88–0.96 in
// light and 0.04–0.09 in dark, blended 90/10 with systemGroupedBackground) drawn at 42 %, then
// the dim, 25 % white in light and 35 % black in dark. In the list strip every segment carries
// its own photo's tint and the dim is drawn once over the blurred strip, so where segments blend
// the pixels and the tints blend alike (`composite` with blended inputs). Worst cases, over
// every average colour and over blends of any two tints or of a tint and the plain base
// (swept in PickrAppTests' AmbientPaletteTests):
//
//   light, a black region under black text:   5.62 : 1 (the tint of a dark blue photo)
//   dark,  a white region under white text:   5.58 : 1 (the tint of a white photo)
//
// Blends never go below the single-photo figures. The dim alone would give 2.02 : 1 and
// 2.44 : 1, so the tint is never left out: every backdrop carries its average colour. Reduce
// Transparency and Increase Contrast get the plain background.

/// Colour math for ambient backgrounds. Every member is a pure function of its arguments.
nonisolated enum AmbientPalette {
    /// An sRGB colour, each channel 0...1 (gamma-encoded, as stored in a bitmap).
    struct RGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        /// Clamps each channel to 0...1.
        init(red: Double, green: Double, blue: Double) {
            self.red = Self.clamp(red)
            self.green = Self.clamp(green)
            self.blue = Self.clamp(blue)
        }

        /// From 8-bit channels, for example `RGB(bytes: 242, 242, 247)`.
        init(bytes red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        }

        private static func clamp(_ value: Double) -> Double {
            value.isFinite ? min(max(value, 0), 1) : 0
        }
    }

    /// Hue, saturation and lightness, each 0...1 (hue wraps at 1).
    struct HSL: Hashable, Sendable {
        var hue: Double
        var saturation: Double
        var lightness: Double
    }

    /// The colour scheme a colour is tamed for.
    enum Appearance: Hashable, Sendable {
        case light, dark
    }

    // MARK: Constants (§3.5)

    /// The highest saturation a tamed colour keeps.
    static let maximumSaturation = 0.45
    /// The tint over a blurred photo: tamed at this weight, drawn at `photoTintOpacity`.
    static let photoTintWeight = 0.9
    static let photoTintOpacity = 0.42
    /// The Gaussian blur baked into each 64 px backdrop, in its pixels: about a 60 pt blur once
    /// the backdrop is scaled to a phone-width screen. Baked in because a live SwiftUI blur on
    /// the background layer rendered black on device (and cost a full-screen blur per frame).
    static let backdropBlurRadius = 9.0
    static let photoSaturation = 0.8
    /// The contrast primary text must keep on the background.
    static let minimumTextContrast = 4.5

    /// The lightness band a tamed colour is mapped into.
    static func lightnessBand(for appearance: Appearance) -> ClosedRange<Double> {
        switch appearance {
        case .light: 0.88...0.96
        case .dark: 0.04...0.09
        }
    }

    /// `systemGroupedBackground`: #F2F2F7 in light, black in dark.
    static func screen(for appearance: Appearance) -> RGB {
        switch appearance {
        case .light: RGB(bytes: 242, 242, 247)
        case .dark: RGB(red: 0, green: 0, blue: 0)
        }
    }

    /// Primary text (`label`): black in light, white in dark.
    static func primaryText(for appearance: Appearance) -> RGB {
        switch appearance {
        case .light: RGB(red: 0, green: 0, blue: 0)
        case .dark: RGB(red: 1, green: 1, blue: 1)
        }
    }

    /// The dimming over a blurred photo: 25 % white in light, 35 % black in dark.
    static func photoDim(for appearance: Appearance) -> (color: RGB, opacity: Double) {
        switch appearance {
        case .light: (RGB(red: 1, green: 1, blue: 1), 0.25)
        case .dark: (RGB(red: 0, green: 0, blue: 0), 0.35)
        }
    }

    // MARK: Averages

    /// The average colour of premultiplied RGBA8 pixels (4 bytes per pixel), weighted by
    /// alpha. `nil` when there are no pixels or every pixel is transparent.
    static func averageColor(rgba bytes: [UInt8]) -> RGB? {
        guard bytes.count >= 4 else { return nil }
        var red = 0, green = 0, blue = 0, alpha = 0
        var index = 0
        while index + 3 < bytes.count {
            red += Int(bytes[index])
            green += Int(bytes[index + 1])
            blue += Int(bytes[index + 2])
            alpha += Int(bytes[index + 3])
            index += 4
        }
        guard alpha > 0 else { return nil }
        // Premultiplied sums divided by the alpha sum un-premultiply the average.
        let total = Double(alpha)
        return RGB(red: Double(red) / total, green: Double(green) / total, blue: Double(blue) / total)
    }

    // MARK: Taming

    /// Tames a photo colour into a background colour: saturation clamped to 0.45,
    /// lightness mapped linearly into the band for `appearance`, then blended
    /// `weight : 1 − weight` with `systemGroupedBackground`.
    static func tamed(_ color: RGB, for appearance: Appearance, weight: Double) -> RGB {
        var hsl = hsl(from: color)
        let band = lightnessBand(for: appearance)
        hsl.saturation = min(hsl.saturation, maximumSaturation)
        hsl.lightness = band.lowerBound + hsl.lightness * (band.upperBound - band.lowerBound)
        return mix(rgb(from: hsl), screen(for: appearance), weight: weight)
    }

    /// The tint laid over a blurred photo at `photoTintOpacity`.
    static func photoTint(_ color: RGB, for appearance: Appearance) -> RGB {
        tamed(color, for: appearance, weight: photoTintWeight)
    }

    /// What `pixel` of the blurred backdrop (after its saturation filter, which leaves black
    /// and white, the worst cases, as they are) becomes on screen, for a photo whose average
    /// colour is `average`: the tint at `photoTintOpacity`, then the dim, as
    /// `AmbientColor.swift` draws them.
    static func photoComposite(_ pixel: RGB, average: RGB, for appearance: Appearance) -> RGB {
        composite(pixel, tint: photoTint(average, for: appearance), for: appearance)
    }

    /// What `pixel` becomes under `tint` at `photoTintOpacity`, then the dim. Where strip
    /// segments blend, the pixels and the tints blend alike before the one dim, so a blend is
    /// this with blended pixels and tints.
    static func composite(_ pixel: RGB, tint: RGB, for appearance: Appearance) -> RGB {
        let tinted = mix(tint, pixel, weight: photoTintOpacity)
        let dim = photoDim(for: appearance)
        return mix(dim.color, tinted, weight: dim.opacity)
    }

    /// `a × weight + b × (1 − weight)`, channel by channel.
    static func mix(_ a: RGB, _ b: RGB, weight: Double) -> RGB {
        let w = min(max(weight, 0), 1)
        return RGB(
            red: a.red * w + b.red * (1 - w),
            green: a.green * w + b.green * (1 - w),
            blue: a.blue * w + b.blue * (1 - w)
        )
    }

    // MARK: HSL

    static func hsl(from color: RGB) -> HSL {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        let lightness = (high + low) / 2
        guard high > low else { return HSL(hue: 0, saturation: 0, lightness: lightness) }

        let delta = high - low
        let saturation = lightness > 0.5 ? delta / (2 - high - low) : delta / (high + low)
        var hue: Double
        switch high {
        case color.red: hue = (color.green - color.blue) / delta + (color.green < color.blue ? 6 : 0)
        case color.green: hue = (color.blue - color.red) / delta + 2
        default: hue = (color.red - color.green) / delta + 4
        }
        hue /= 6
        return HSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    static func rgb(from hsl: HSL) -> RGB {
        let s = min(max(hsl.saturation, 0), 1)
        let l = min(max(hsl.lightness, 0), 1)
        guard s > 0 else { return RGB(red: l, green: l, blue: l) }

        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ offset: Double) -> Double {
            var t = hsl.hue + offset
            t -= t.rounded(.down)
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(red: channel(1.0 / 3), green: channel(0), blue: channel(-1.0 / 3))
    }

    // MARK: Contrast (WCAG 2)

    /// Relative luminance of an sRGB colour, 0 (black) to 1 (white).
    static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// The contrast ratio between two colours, 1...21.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
