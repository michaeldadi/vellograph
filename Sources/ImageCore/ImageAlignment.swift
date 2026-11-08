import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Vision

public struct ImageSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public static func load(_ url: URL) throws -> ImageSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw PixelDifferenceError.unreadableImage
        }
        return ImageSize(width: width, height: height)
    }
}

/// The position of image B's top-left pixel relative to image A's top-left pixel.
/// Positive X moves B right; positive Y moves B down.
public struct ImageTranslation: Sendable, Equatable {
    public var x: Int
    public var y: Int

    public init(x: Int = 0, y: Int = 0) {
        self.x = x
        self.y = y
    }
}

public struct ImageCanvas: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let leftX: Int
    public let leftY: Int
    public let rightX: Int
    public let rightY: Int

    public init(leftWidth: Int, leftHeight: Int, rightWidth: Int, rightHeight: Int,
                translation: ImageTranslation = .init()) throws {
        guard leftWidth > 0, leftHeight > 0, rightWidth > 0, rightHeight > 0 else {
            throw PixelDifferenceError.unreadableImage
        }
        guard translation.x != Int.min, translation.y != Int.min else {
            throw PixelDifferenceError.imageTooLarge
        }
        let leftX = max(0, -translation.x)
        let leftY = max(0, -translation.y)
        let rightX = max(0, translation.x)
        let rightY = max(0, translation.y)
        let leftMaxX = leftX.addingReportingOverflow(leftWidth)
        let rightMaxX = rightX.addingReportingOverflow(rightWidth)
        let leftMaxY = leftY.addingReportingOverflow(leftHeight)
        let rightMaxY = rightY.addingReportingOverflow(rightHeight)
        let width = max(leftMaxX.partialValue, rightMaxX.partialValue)
        let height = max(leftMaxY.partialValue, rightMaxY.partialValue)
        guard !leftMaxX.overflow, !rightMaxX.overflow,
              !leftMaxY.overflow, !rightMaxY.overflow,
              width > 0, height > 0,
              width <= 25_000_000 / height else {
            throw PixelDifferenceError.imageTooLarge
        }
        self.width = width
        self.height = height
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
    }
}

public enum ImageAnchor: String, Sendable, CaseIterable {
    case topLeft = "Top Left", top = "Top", topRight = "Top Right"
    case left = "Left", center = "Center", right = "Right"
    case bottomLeft = "Bottom Left", bottom = "Bottom", bottomRight = "Bottom Right"

    private var fractions: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }

    public func translation(leftWidth: Int, leftHeight: Int,
                            rightWidth: Int, rightHeight: Int,
                            adjustment: ImageTranslation = .init()) -> ImageTranslation {
        let point = fractions
        return ImageTranslation(
            x: Int((Double(leftWidth - rightWidth) * point.x).rounded()) + adjustment.x,
            y: Int((Double(leftHeight - rightHeight) * point.y).rounded()) + adjustment.y
        )
    }
}

public enum ImageRegistration {
    /// Vision returns a Core Graphics transform with upward-positive Y.
    /// Convert to the top-left, downward-positive coordinates used by the canvas.
    public static func translation(left: URL, right: URL) throws -> ImageTranslation {
        try Task<Never, Never>.checkCancellation()
        guard let leftSource = CGImageSourceCreateWithURL(left as CFURL, nil),
              let rightSource = CGImageSourceCreateWithURL(right as CFURL, nil),
              let reference = CGImageSourceCreateImageAtIndex(leftSource, 0, nil),
              let floating = CGImageSourceCreateImageAtIndex(rightSource, 0, nil) else {
            throw PixelDifferenceError.unreadableImage
        }
        guard reference.width > 0, reference.height > 0,
              floating.width > 0, floating.height > 0,
              reference.width <= 25_000_000 / reference.height,
              floating.width <= 25_000_000 / floating.height else {
            throw PixelDifferenceError.imageTooLarge
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating)
        try VNImageRequestHandler(cgImage: reference).perform([request])
        try Task<Never, Never>.checkCancellation()
        guard let transform = request.results?.first?.alignmentTransform,
              transform.tx.isFinite, transform.ty.isFinite else {
            throw PixelDifferenceError.alignmentFailed
        }
        return ImageTranslation(x: Int(transform.tx.rounded()),
                                y: Int((-transform.ty).rounded()))
    }

    /// Produces a local, color-managed PNG of B warped into A's pixel space.
    /// Vision works best when both images depict substantially the same scene.
    public static func perspectiveAligned(left: URL, right: URL) throws -> Data {
        try Task<Never, Never>.checkCancellation()
        guard let leftSource = CGImageSourceCreateWithURL(left as CFURL, nil),
              let rightSource = CGImageSourceCreateWithURL(right as CFURL, nil),
              let reference = CGImageSourceCreateImageAtIndex(leftSource, 0, nil),
              let floating = CGImageSourceCreateImageAtIndex(rightSource, 0, nil) else {
            throw PixelDifferenceError.unreadableImage
        }
        guard reference.width > 0, reference.height > 0,
              floating.width > 0, floating.height > 0,
              reference.width <= 25_000_000 / reference.height,
              floating.width <= 25_000_000 / floating.height else {
            throw PixelDifferenceError.imageTooLarge
        }
        let floatingImage = CIImage(cgImage: floating)
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: floatingImage)
        try VNImageRequestHandler(ciImage: CIImage(cgImage: reference)).perform([request])
        try Task<Never, Never>.checkCancellation()
        guard let observation = request.results?.first,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PixelDifferenceError.alignmentFailed
        }
        let matrix = observation.warpTransform
        func warpedCorner(_ x: Int, _ y: Int) throws -> CGPoint {
            let vector = matrix * SIMD3<Float>(Float(x), Float(y), 1)
            guard vector.z.isFinite, abs(vector.z) > 0.000_001 else {
                throw PixelDifferenceError.alignmentFailed
            }
            let point = CGPoint(x: CGFloat(vector.x / vector.z), y: CGFloat(vector.y / vector.z))
            let bound = CGFloat(max(reference.width, reference.height) * 8)
            guard point.x.isFinite, point.y.isFinite,
                  abs(point.x) < bound, abs(point.y) < bound else {
                throw PixelDifferenceError.alignmentFailed
            }
            return point
        }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = floatingImage
        filter.topLeft = try warpedCorner(0, floating.height)
        filter.topRight = try warpedCorner(floating.width, floating.height)
        filter.bottomLeft = try warpedCorner(0, 0)
        filter.bottomRight = try warpedCorner(floating.width, 0)
        let referenceRect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        guard let transformed = filter.outputImage?.cropped(to: referenceRect) else {
            throw PixelDifferenceError.renderingFailed
        }
        let aligned = transformed.composited(over: CIImage(color: .clear).cropped(to: referenceRect))
        let context = CIContext()
        guard let png = context.pngRepresentation(of: aligned, format: .RGBA8,
                                                  colorSpace: colorSpace) else {
            throw PixelDifferenceError.renderingFailed
        }
        try Task<Never, Never>.checkCancellation()
        return png
    }
}
