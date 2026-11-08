import CoreGraphics
import Foundation
import ImageIO

public enum PixelDifferenceError: Error, LocalizedError, Equatable {
    case unreadableImage
    case imageTooLarge
    case renderingFailed
    case alignmentFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "The image could not be decoded."
        case .imageTooLarge: "This image pair exceeds the 25-million-pixel difference limit."
        case .renderingFailed: "The image difference could not be rendered."
        case .alignmentFailed: "These images could not be aligned by their content. Try a manual offset."
        }
    }
}

public enum PixelDifferenceMode: String, Sendable, CaseIterable {
    case absolute = "Absolute"
    case proportional = "Proportional"
}

public enum PixelMaskColor: String, Sendable, CaseIterable {
    case red = "Red"
    case magenta = "Magenta"
    case cyan = "Cyan"
    case yellow = "Yellow"

    var rgb: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .red: (255, 0, 0)
        case .magenta: (255, 0, 255)
        case .cyan: (0, 255, 255)
        case .yellow: (255, 220, 0)
        }
    }
}

public struct PixelDifferenceMask: Sendable {
    public let width: Int
    public let height: Int
    public let canvas: ImageCanvas
    public let sameDimensions: Bool
    public let rgba: Data
    public let changedPixelCount: Int
    public let totalPixelCount: Int
}

public struct PixelSample: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(x: Int, y: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.x = x
        self.y = y
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hex: String {
        String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }
}

public struct ImageColorInformation: Sendable, Equatable {
    public let sourceModel: String
    public let sourceProfile: String
    public let sourceDepth: Int

    public init(sourceModel: String, sourceProfile: String, sourceDepth: Int) {
        self.sourceModel = sourceModel
        self.sourceProfile = sourceProfile
        self.sourceDepth = sourceDepth
    }
}

public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let colorInformation: ImageColorInformation
    fileprivate let rgba: Data

    public static func load(_ url: URL) throws -> PixelBuffer {
        try Task<Never, Never>.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PixelDifferenceError.unreadableImage
        }
        return try load(source)
    }

    public static func load(data: Data) throws -> PixelBuffer {
        try Task<Never, Never>.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PixelDifferenceError.unreadableImage
        }
        return try load(source)
    }

    private static func load(_ source: CGImageSource) throws -> PixelBuffer {
        // Check dimensions from the encoded header before ImageIO allocates a
        // decoded bitmap. A compressed image can be tiny on disk and enormous
        // when expanded.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let encodedWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let encodedHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              encodedWidth > 0, encodedHeight > 0 else {
            throw PixelDifferenceError.unreadableImage
        }
        guard encodedWidth <= 25_000_000 / encodedHeight else {
            throw PixelDifferenceError.imageTooLarge
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PixelDifferenceError.unreadableImage
        }
        guard image.width > 0, image.height > 0,
              image.width <= 25_000_000 / image.height else {
            throw PixelDifferenceError.imageTooLarge
        }
        let profile = properties[kCGImagePropertyProfileName] as? String
            ?? properties[kCGImagePropertyNamedColorSpace] as? String
            ?? "Unspecified"
        let model = properties[kCGImagePropertyColorModel] as? String ?? "Unknown"
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? image.bitsPerComponent
        return PixelBuffer(width: image.width, height: image.height,
                           colorInformation: ImageColorInformation(
                            sourceModel: model, sourceProfile: profile, sourceDepth: depth),
                           rgba: try PixelDifference.bitmap(image, width: image.width,
                                                            height: image.height))
    }

    /// Normalized coordinates are measured from the displayed top-left corner.
    public func sample(x: Double, y: Double) -> PixelSample? {
        guard x >= 0, x < 1, y >= 0, y < 1 else { return nil }
        return sample(pixelX: Int(x * Double(width)), pixelY: Int(y * Double(height)))
    }

    /// Pixel coordinates are measured from the displayed top-left corner.
    public func sample(pixelX column: Int, pixelY row: Int) -> PixelSample? {
        guard column >= 0, column < width, row >= 0, row < height else { return nil }
        let offset = (row * width + column) * 4
        return rgba.withUnsafeBytes { bytes in
            guard offset + 3 < bytes.count,
                  let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let alpha = base[offset + 3]
            func unpremultiply(_ value: UInt8) -> UInt8 {
                guard alpha > 0 else { return 0 }
                return UInt8(min(255, (Int(value) * 255 + Int(alpha) / 2) / Int(alpha)))
            }
            return PixelSample(x: column, y: row,
                               red: unpremultiply(base[offset]),
                               green: unpremultiply(base[offset + 1]),
                               blue: unpremultiply(base[offset + 2]),
                               alpha: alpha)
        }
    }
}

public enum PixelDifference {
    public static func compare(
        left: URL,
        right: URL,
        mode: PixelDifferenceMode = .absolute,
        threshold: Double = 0.02,
        maskColor: PixelMaskColor = .red,
        translation: ImageTranslation = .init()
    ) throws -> PixelDifferenceMask {
        try Task<Never, Never>.checkCancellation()
        let a = try PixelBuffer.load(left)
        let b = try PixelBuffer.load(right)
        return try compare(a, b, mode: mode, threshold: threshold,
                           maskColor: maskColor, translation: translation)
    }

    public static func compare(
        left: URL,
        rightData: Data,
        mode: PixelDifferenceMode = .absolute,
        threshold: Double = 0.02,
        maskColor: PixelMaskColor = .red
    ) throws -> PixelDifferenceMask {
        try compare(try PixelBuffer.load(left), try PixelBuffer.load(data: rightData),
                    mode: mode, threshold: threshold, maskColor: maskColor,
                    translation: .init())
    }

    private static func compare(
        _ a: PixelBuffer, _ b: PixelBuffer,
        mode: PixelDifferenceMode, threshold: Double,
        maskColor: PixelMaskColor, translation: ImageTranslation
    ) throws -> PixelDifferenceMask {
        let canvas = try ImageCanvas(leftWidth: a.width, leftHeight: a.height,
                                     rightWidth: b.width, rightHeight: b.height,
                                     translation: translation)
        let width = canvas.width
        let height = canvas.height
        let limit = UInt8((min(1, max(0, threshold)) * 255).rounded())
        var mask = Data(count: width * height * 4)
        var changed = 0
        try mask.withUnsafeMutableBytes { destination in
            try a.rgba.withUnsafeBytes { leftBytes in
                try b.rgba.withUnsafeBytes { rightBytes in
                    guard let out = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let lhs = leftBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let rhs = rightBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for row in 0..<height {
                        try Task<Never, Never>.checkCancellation()
                        for column in 0..<width {
                            let offset = (row * width + column) * 4
                            let ax = column - canvas.leftX
                            let ay = row - canvas.leftY
                            let bx = column - canvas.rightX
                            let by = row - canvas.rightY
                            let leftInside = ax >= 0 && ax < a.width && ay >= 0 && ay < a.height
                            let rightInside = bx >= 0 && bx < b.width && by >= 0 && by < b.height
                            let leftOffset = (ay * a.width + ax) * 4
                            let rightOffset = (by * b.width + bx) * 4
                            var magnitude = 0
                            var brightness = 0
                            for channel in 0..<4 {
                                let leftValue = leftInside ? Int(lhs[leftOffset + channel]) : 0
                                let rightValue = rightInside ? Int(rhs[rightOffset + channel]) : 0
                                magnitude = max(magnitude, abs(leftValue - rightValue))
                                brightness = max(brightness, leftValue, rightValue)
                            }
                            let effective = mode == .absolute
                                ? magnitude
                                : min(255, magnitude * 255 / max(16, brightness))
                            if effective > Int(limit) {
                                changed += 1
                                // Premultiply the selected color for CGImage rendering.
                                let alpha = UInt8(max(80, effective))
                                let rgb = maskColor.rgb
                                out[offset] = UInt8(Int(rgb.red) * Int(alpha) / 255)
                                out[offset + 1] = UInt8(Int(rgb.green) * Int(alpha) / 255)
                                out[offset + 2] = UInt8(Int(rgb.blue) * Int(alpha) / 255)
                                out[offset + 3] = alpha
                            }
                        }
                    }
                }
            }
        }
        return PixelDifferenceMask(width: width, height: height, canvas: canvas,
                                   sameDimensions: a.width == b.width && a.height == b.height,
                                   rgba: mask,
                                   changedPixelCount: changed, totalPixelCount: width * height)
    }

    fileprivate static func bitmap(_ image: CGImage, width: Int, height: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PixelDifferenceError.renderingFailed
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: info.rawValue),
              let pointer = context.data else { throw PixelDifferenceError.renderingFailed }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: pointer, count: width * height * 4)
    }
}
