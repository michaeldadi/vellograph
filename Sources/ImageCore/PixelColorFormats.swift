import Foundation

public enum PixelColorFormat: String, CaseIterable, Sendable {
    case rgb = "RGB"
    case hsb = "HSB"
    case hsl = "HSL"
    case lab = "Lab"
}

public struct PixelColorComponent: Sendable, Equatable {
    public let name: String
    public let value: Double
    public let unit: String

    public init(name: String, value: Double, unit: String = "") {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

public enum PixelColorConversion {
    /// Values are calculated from the inspector's 8-bit sRGB sample.
    public static func components(of sample: PixelSample, in format: PixelColorFormat) -> [PixelColorComponent] {
        let r = Double(sample.red) / 255
        let g = Double(sample.green) / 255
        let b = Double(sample.blue) / 255
        switch format {
        case .rgb:
            return [
                .init(name: "R", value: Double(sample.red)),
                .init(name: "G", value: Double(sample.green)),
                .init(name: "B", value: Double(sample.blue)),
            ]
        case .hsb, .hsl:
            let high = max(r, g, b)
            let low = min(r, g, b)
            let spread = high - low
            let hue: Double
            if spread == 0 { hue = 0 }
            else if high == r { hue = 60 * ((g - b) / spread).truncatingRemainder(dividingBy: 6) }
            else if high == g { hue = 60 * ((b - r) / spread + 2) }
            else { hue = 60 * ((r - g) / spread + 4) }
            let normalizedHue = hue < 0 ? hue + 360 : hue
            if format == .hsb {
                return [
                    .init(name: "H", value: normalizedHue, unit: "°"),
                    .init(name: "S", value: high == 0 ? 0 : spread / high * 100, unit: "%"),
                    .init(name: "B", value: high * 100, unit: "%"),
                ]
            }
            let lightness = (high + low) / 2
            let saturation = spread == 0 ? 0 : spread / (1 - abs(2 * lightness - 1))
            return [
                .init(name: "H", value: normalizedHue, unit: "°"),
                .init(name: "S", value: saturation * 100, unit: "%"),
                .init(name: "L", value: lightness * 100, unit: "%"),
            ]
        case .lab:
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let lr = linear(r), lg = linear(g), lb = linear(b)
            let x = (lr * 0.4124564 + lg * 0.3575761 + lb * 0.1804375) / 0.95047
            let y = lr * 0.2126729 + lg * 0.7151522 + lb * 0.0721750
            let z = (lr * 0.0193339 + lg * 0.1191920 + lb * 0.9503041) / 1.08883
            let delta = 6.0 / 29
            func f(_ value: Double) -> Double {
                value > delta * delta * delta
                    ? cbrt(value)
                    : value / (3 * delta * delta) + 4.0 / 29
            }
            let fx = f(x), fy = f(y), fz = f(z)
            return [
                .init(name: "L*", value: 116 * fy - 16),
                .init(name: "a*", value: 500 * (fx - fy)),
                .init(name: "b*", value: 200 * (fy - fz)),
            ]
        }
    }

    /// Normalized RMS difference across RGBA channels, zero for equal samples.
    public static func relativeDifference(_ a: PixelSample, _ b: PixelSample) -> Double {
        let dr = Double(Int(a.red) - Int(b.red)) / 255
        let dg = Double(Int(a.green) - Int(b.green)) / 255
        let db = Double(Int(a.blue) - Int(b.blue)) / 255
        let da = Double(Int(a.alpha) - Int(b.alpha)) / 255
        return sqrt((dr * dr + dg * dg + db * db + da * da) / 4)
    }
}
