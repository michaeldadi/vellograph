import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageCore
import ImageIO
import Testing
import UniformTypeIdentifiers

@Test func navigatorViewportCentersAndClamps() {
    let viewport = ImageViewport(canvasWidth: 1000, canvasHeight: 500,
                                 viewportWidth: 500, viewportHeight: 300, zoom: 2)
    #expect(viewport.fitScale == 0.5)
    #expect(viewport.visibleRect(panX: 0, panY: 0) ==
            ImageViewportRect(x: 250, y: 100, width: 500, height: 300))
    let edge = viewport.panToCenter(x: 1000, y: 500)
    #expect(edge.x == -250)
    #expect(edge.y == -100)
    #expect(viewport.visibleRect(panX: edge.x, panY: edge.y) ==
            ImageViewportRect(x: 500, y: 200, width: 500, height: 300))
    let fitted = ImageViewport(canvasWidth: 1000, canvasHeight: 500,
                               viewportWidth: 500, viewportHeight: 300, zoom: 1)
    #expect(fitted.visibleRect(panX: 500, panY: -500) ==
            ImageViewportRect(x: 0, y: 0, width: 1000, height: 500))
}

@Test func oneChangedPixelProducesOneVisibleMaskPixel() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let left = directory.appending(path: "left.png")
    let right = directory.appending(path: "right.png")
    try writePNG([255, 0, 0, 255, 255, 0, 0, 255], to: left)
    try writePNG([255, 0, 0, 255, 0, 0, 255, 255], to: right)

    let result = try PixelDifference.compare(left: left, right: right, threshold: 0)
    #expect(result.width == 2)
    #expect(result.height == 1)
    #expect(result.sameDimensions)
    #expect(!result.isPreview)
    #expect(result.changedPixelCount == 1)
    #expect(Array(result.rgba.prefix(4)) == [0, 0, 0, 0])
    #expect(result.rgba[7] > 0)
    let yellow = try PixelDifference.compare(left: left, right: right,
                                             threshold: 0, maskColor: .yellow)
    #expect(yellow.changedPixelCount == result.changedPixelCount)
    #expect(Array(yellow.rgba[4..<8]) == [255, 220, 0, 255])
}

@Test func pixelBufferReadsBothSidesOfAnImage() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try writePNG([255, 0, 0, 255, 0, 0, 255, 255], to: url)
    let buffer = try PixelBuffer.load(url)
    #expect(buffer.width == 2)
    #expect(buffer.height == 1)
    #expect(buffer.sample(x: 0.25, y: 0.5)?.hex == "#FF0000FF")
    #expect(buffer.sample(x: 0.75, y: 0.5)?.hex == "#0000FFFF")
    #expect(buffer.sample(x: 1, y: 0.5) == nil)
    #expect(buffer.colorInformation.sourceDepth == 8)
}

@Test func compressedOversizeImageIsRejectedBeforeDecoding() throws {
    let huge = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/huge-solid.png")
    let size = try ImageSize.load(huge)
    #expect(size.width == 8192 && size.height == 8192)
    #expect(try Data(contentsOf: huge).count < 1_000_000)
    #expect(throws: PixelDifferenceError.imageTooLarge) { try PixelBuffer.load(huge) }
    #expect(throws: PixelDifferenceError.imageTooLarge) {
        try PixelBuffer.load(data: Data(contentsOf: huge))
    }
    #expect(throws: PixelDifferenceError.imageTooLarge) {
        try ImageRegistration.translation(left: huge, right: huge)
    }
    #expect(throws: PixelDifferenceError.imageTooLarge) {
        try ImageRegistration.perspectiveAligned(left: huge, right: huge)
    }
    let canvas = try ImageCanvas(leftWidth: size.width, leftHeight: size.height,
                                 rightWidth: size.width, rightHeight: size.height)
    #expect(canvas.width == 8192 && canvas.height == 8192)
    let preview = try PixelDifference.compare(left: huge, right: huge)
    #expect(preview.isPreview)
    #expect(preview.width < size.width && preview.height < size.height)
    #expect(preview.totalPixelCount <= 25_000_000)
    #expect(preview.changedPixelCount == 0)
    #expect(throws: PixelDifferenceError.imageTooLarge) {
        try ImageCanvas(leftWidth: 100_000, leftHeight: 100_000,
                        rightWidth: 100_000, rightHeight: 100_000)
    }
}

@Test func sRGBPixelFormatsHaveExpectedPrimaryAndNeutralValues() {
    let red = PixelSample(x: 0, y: 0, red: 255, green: 0, blue: 0, alpha: 255)
    let white = PixelSample(x: 1, y: 0, red: 255, green: 255, blue: 255, alpha: 255)
    let hsb = PixelColorConversion.components(of: red, in: .hsb)
    let hsl = PixelColorConversion.components(of: red, in: .hsl)
    let lab = PixelColorConversion.components(of: red, in: .lab)
    let whiteLab = PixelColorConversion.components(of: white, in: .lab)
    #expect(hsb.map(\.value) == [0, 100, 100])
    #expect(hsl.map(\.value) == [0, 100, 50])
    #expect(abs(lab[0].value - 53.24) < 0.1)
    #expect(abs(lab[1].value - 80.09) < 0.2)
    #expect(abs(lab[2].value - 67.2) < 0.2)
    #expect(abs(whiteLab[0].value - 100) < 0.01)
    #expect(PixelColorConversion.relativeDifference(red, red) == 0)
    #expect(PixelColorConversion.relativeDifference(red, white) > 0.7)
}

@Test func pixelBufferUsesDisplayedTopLeftCoordinates() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try writePNG([255, 0, 0, 255, 0, 0, 255, 255,
                  0, 255, 0, 255, 255, 255, 255, 255], to: url,
                 width: 2, height: 2)
    let buffer = try PixelBuffer.load(url)
    #expect(buffer.sample(x: 0.25, y: 0.25)?.hex == "#FF0000FF")
    #expect(buffer.sample(x: 0.75, y: 0.75)?.hex == "#FFFFFFFF")
}

@Test func translatedDifferenceUsesSharedCanvas() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let left = directory.appending(path: "left.png")
    let right = directory.appending(path: "right.png")
    try writePNG([255, 0, 0, 255], to: left, width: 1, height: 1)
    try writePNG([255, 0, 0, 255], to: right, width: 1, height: 1)

    let equal = try PixelDifference.compare(left: left, right: right, threshold: 0)
    #expect(equal.changedPixelCount == 0)
    let shifted = try PixelDifference.compare(left: left, right: right,
                                              threshold: 0, translation: .init(x: 1, y: 0))
    let expectedCanvas = try ImageCanvas(leftWidth: 1, leftHeight: 1,
                                         rightWidth: 1, rightHeight: 1,
                                         translation: .init(x: 1, y: 0))
    #expect(shifted.canvas == expectedCanvas)
    #expect(shifted.width == 2)
    #expect(shifted.changedPixelCount == 2)
}

@Test func anchorPositionsAlignDifferentSizedImages() {
    #expect(ImageAnchor.topLeft.translation(leftWidth: 10, leftHeight: 20,
                                             rightWidth: 6, rightHeight: 12) == .init())
    #expect(ImageAnchor.center.translation(leftWidth: 10, leftHeight: 20,
                                            rightWidth: 6, rightHeight: 12) == .init(x: 2, y: 4))
    #expect(ImageAnchor.bottomRight.translation(leftWidth: 10, leftHeight: 20,
                                                 rightWidth: 6, rightHeight: 12,
                                                 adjustment: .init(x: -1, y: 1)) == .init(x: 3, y: 9))
}

@Test func visionTranslationAlignsShiftedContent() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let left = directory.appending(path: "reference.png")
    let right = directory.appending(path: "floating.png")
    let width = 128
    let height = 128
    var source = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let mark = ((x * 47 + y * 89 + x * y * 3) % 131) < 31
            source[index] = mark ? 240 : 22
            source[index + 1] = mark ? 70 : 24
            source[index + 2] = mark ? 180 : 28
            source[index + 3] = 255
        }
    }
    var shifted = [UInt8](repeating: 0, count: source.count)
    for y in 0..<height {
        for x in 0..<width {
            let destination = (y * width + x) * 4
            let oldX = x - 8
            let oldY = y + 5
            if oldX >= 0, oldX < width, oldY >= 0, oldY < height {
                let old = (oldY * width + oldX) * 4
                shifted[destination..<(destination + 4)] = source[old..<(old + 4)]
            } else {
                shifted[destination + 3] = 255
            }
        }
    }
    try writePNG(source, to: left, width: width, height: height)
    try writePNG(shifted, to: right, width: width, height: height)
    let alignment = try ImageRegistration.translation(left: left, right: right)
    #expect(abs(alignment.x + 8) <= 2)
    #expect(abs(alignment.y - 5) <= 2)
}

@Test func visionPerspectiveAlignmentImprovesWarpedPair() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reference = directory.appending(path: "reference.png")
    let floating = directory.appending(path: "floating.png")
    let width = 1254
    let height = 1254
    try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Artwork/VellographIcon-master.png"), to: reference)
    let filter = CIFilter.perspectiveTransform()
    filter.inputImage = CIImage(contentsOf: reference)
    filter.topLeft = CGPoint(x: -5, y: height + 7)
    filter.topRight = CGPoint(x: width + 11, y: height + 2)
    filter.bottomLeft = CGPoint(x: -10, y: -3)
    filter.bottomRight = CGPoint(x: width + 3, y: -13)
    guard let warped = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)),
          let data = CIContext().pngRepresentation(of: warped, format: .RGBA8,
                                                    colorSpace: CGColorSpaceCreateDeviceRGB()) else {
        throw PixelDifferenceError.renderingFailed
    }
    try data.write(to: floating)

    let before = try PixelDifference.compare(left: reference, right: floating, threshold: 0.1)
    let aligned = try ImageRegistration.perspectiveAligned(left: reference, right: floating)
    let after = try PixelDifference.compare(left: reference, rightData: aligned, threshold: 0.1)
    #expect(after.sameDimensions)
    #expect(after.changedPixelCount < before.changedPixelCount * 8 / 10,
            "Before \(before.changedPixelCount), after \(after.changedPixelCount)")
}

private func writePNG(_ pixels: [UInt8], to url: URL,
                      width: Int = 2, height: Int = 1) throws {
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                              bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                .union(.byteOrder32Big),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw PixelDifferenceError.renderingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw PixelDifferenceError.renderingFailed }
}
