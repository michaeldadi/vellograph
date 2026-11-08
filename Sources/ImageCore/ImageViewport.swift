import Foundation

public struct ImageViewportRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Shared fit, pan, and navigator geometry in top-left image coordinates.
public struct ImageViewport: Sendable {
    public let canvasWidth: Double
    public let canvasHeight: Double
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let zoom: Double

    public init(canvasWidth: Double, canvasHeight: Double,
                viewportWidth: Double, viewportHeight: Double, zoom: Double) {
        self.canvasWidth = max(1, canvasWidth)
        self.canvasHeight = max(1, canvasHeight)
        self.viewportWidth = max(1, viewportWidth)
        self.viewportHeight = max(1, viewportHeight)
        self.zoom = max(0.001, zoom)
    }

    public var fitScale: Double {
        min(viewportWidth / canvasWidth, viewportHeight / canvasHeight)
    }

    public var displayedScale: Double { fitScale * zoom }

    public func clampedPan(x: Double, y: Double) -> (x: Double, y: Double) {
        let maxX = max(0, (canvasWidth * displayedScale - viewportWidth) / 2)
        let maxY = max(0, (canvasHeight * displayedScale - viewportHeight) / 2)
        return (min(max(x, -maxX), maxX), min(max(y, -maxY), maxY))
    }

    public func panToCenter(x: Double, y: Double) -> (x: Double, y: Double) {
        clampedPan(x: (canvasWidth / 2 - x) * displayedScale,
                   y: (canvasHeight / 2 - y) * displayedScale)
    }

    public func visibleRect(panX: Double, panY: Double) -> ImageViewportRect {
        let pan = clampedPan(x: panX, y: panY)
        let width = min(canvasWidth, viewportWidth / displayedScale)
        let height = min(canvasHeight, viewportHeight / displayedScale)
        let x = min(max(0, canvasWidth / 2 -
                        (viewportWidth / 2 + pan.x) / displayedScale),
                    canvasWidth - width)
        let y = min(max(0, canvasHeight / 2 -
                        (viewportHeight / 2 + pan.y) / displayedScale),
                    canvasHeight - height)
        return ImageViewportRect(x: x, y: y, width: width, height: height)
    }
}
