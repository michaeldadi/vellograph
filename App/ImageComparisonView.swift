import AppKit
import DiffCore
import ImageCore
import SwiftUI
import UniformTypeIdentifiers

struct ImageComparisonView: View {
    let left: URL
    let right: URL
    @Environment(\.pixelLength) private var pixelLength
    @State private var mode: Mode = .twoUp
    @State private var opacity = 0.5
    @State private var split = 0.5
    @State private var showingLeft = true
    @State private var differenceMode: PixelDifferenceMode = .absolute
    @State private var maskColor: PixelMaskColor = .red
    @State private var threshold = 0.02
    @State private var mask: PixelDifferenceMask?
    @State private var maskError: String?
    @State private var imageA: NSImage?
    @State private var imageB: NSImage?
    @State private var alignedImageB: NSImage?
    @State private var alignedImageData: Data?
    @State private var alignmentVersion = UUID()
    @State private var sizeA: ImageSize?
    @State private var sizeB: ImageSize?
    @State private var anchor: ImageAnchor = .topLeft
    @State private var offsetX = 0
    @State private var offsetY = 0
    @State private var autoAligning = false
    @State private var alignmentError: String?
    @State private var selectedOutput: OutputSide = .a
    @State private var savedOutput: URL?
    @State private var saveError: String?
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var viewportSize = CGSize.zero
    @State private var showNavigator = false
    @GestureState private var drag = CGSize.zero
    @State private var inspectPixels = false
    @AppStorage("pixelComparisonFormat") private var colorFormat: PixelColorFormat = .rgb
    @State private var inspectionLocked = false
    @State private var pixelA: PixelBuffer?
    @State private var pixelB: PixelBuffer?
    @State private var inspection: ImageInspection?
    @State private var pixelLoadError: String?
    @State private var loadingPixels = false

    private enum OutputSide: String, CaseIterable {
        case a = "A", b = "B"
    }

    private struct ImageInspection {
        let a: PixelSample?
        let b: PixelSample?
    }

    private var differenceTaskID: String {
        "\(mode.rawValue):\(differenceMode.rawValue):\(maskColor.rawValue):\(threshold):\(translation.x):\(translation.y):\(alignmentVersion)"
    }

    private var translation: ImageTranslation {
        if alignedImageB != nil { return .init() }
        guard let sizeA, let sizeB else { return .init() }
        return anchor.translation(leftWidth: sizeA.width, leftHeight: sizeA.height,
                                  rightWidth: sizeB.width, rightHeight: sizeB.height,
                                  adjustment: .init(x: offsetX, y: offsetY))
    }

    private var canvas: ImageCanvas? {
        guard let sizeA, let sizeB else { return nil }
        return try? ImageCanvas(leftWidth: sizeA.width, leftHeight: sizeA.height,
                                rightWidth: alignedImageB == nil ? sizeB.width : sizeA.width,
                                rightHeight: alignedImageB == nil ? sizeB.height : sizeA.height,
                                translation: translation)
    }

    enum Mode: String, CaseIterable {
        case twoUp = "Two Up", oneUp = "One Up", split = "Split", difference = "Difference"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Image comparison mode")
                    .frame(width: 390)
                    Menu("View Mode") {
                        Button("Two Up") { mode = .twoUp }
                            .keyboardShortcut("1", modifiers: [.command, .option])
                        Button("One Up") { mode = .oneUp }
                            .keyboardShortcut("2", modifiers: [.command, .option])
                        Button("Split") { mode = .split }
                            .keyboardShortcut("3", modifiers: [.command, .option])
                        Button("Difference") { mode = .difference }
                            .keyboardShortcut("4", modifiers: [.command, .option])
                    }
                    Spacer()
                    Button("Fit") {
                        zoom = 1
                        pan = .zero
                    }
                    .disabled(zoom == 1 && pan == .zero)
                    Button("Actual Pixels") {
                        guard let canvas else { return }
                        let viewport = viewportGeometry(canvas: canvas, size: viewportSize)
                        zoom = min(64, max(0.001, Double(pixelLength) / viewport.fitScale))
                        pan = .zero
                    }
                    .disabled(canvas == nil || viewportSize == .zero)
                    Button("Navigator", systemImage: "map") { showNavigator.toggle() }
                        .tint(showNavigator ? .accentColor : .secondary)
                }
                HStack(spacing: 10) {
                    Text("Zoom").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { log2(zoom) },
                                          set: { zoom = pow(2.0, $0) }), in: -10...6)
                        .frame(width: 180)
                        .accessibilityLabel("Image zoom relative to fit")
                    Text("Fit ×\(Int((zoom * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 85, alignment: .trailing)
                    Spacer()
                }
            }
            .padding(12)
            if mode != .twoUp {
                HStack(spacing: 12) {
                    if mode == .oneUp || mode == .difference {
                        Text("Show").fixedSize()
                        Picker("Image to show", selection: $showingLeft) {
                            Text("A").tag(true)
                            Text("B").tag(false)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 88)
                    }
                    if mode == .difference || mode == .split {
                        Text(mode == .split ? "Split" : "Mask opacity").fixedSize()
                        Slider(value: mode == .split ? $split : $opacity).frame(width: 120)
                    }
                    if mode == .difference {
                        Text("Measure").fixedSize()
                        Picker("Measure", selection: $differenceMode) {
                            ForEach(PixelDifferenceMode.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 135)
                        Text("Mask").fixedSize()
                        Picker("Mask Color", selection: $maskColor) {
                            ForEach(PixelMaskColor.allCases, id: \.self) { color in
                                Text(color.rawValue).tag(color)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 125)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                if mode == .difference {
                    HStack(spacing: 12) {
                        Text("Sensitivity").fixedSize()
                        Slider(value: $threshold, in: 0...0.3).frame(width: 180)
                        if let mask {
                            Text("\(mask.changedPixelCount.formatted()) of \(mask.totalPixelCount.formatted()) pixels differ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Toggle("Inspect Pixels", isOn: $inspectPixels)
                        .toggleStyle(.checkbox)
                    if inspectPixels {
                        Button(inspectionLocked ? "Unlock" : "Lock") {
                            inspectionLocked.toggle()
                        }
                        .disabled(inspection == nil)
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        if loadingPixels {
                            ProgressView("Loading pixels…").controlSize(.small)
                        } else if let pixelLoadError {
                            Text(pixelLoadError).foregroundStyle(.secondary)
                        } else if pixelA == nil || pixelB == nil {
                            Text("Preparing pixel samples…")
                                .foregroundStyle(.secondary)
                        } else if inspection == nil {
                            Text("Hover over an image to inspect both sources.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if inspectPixels, inspection != nil {
                        Picker("Color values", selection: $colorFormat) {
                            ForEach(PixelColorFormat.allCases, id: \.self) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .frame(width: 135)
                    }
                }
                if inspectPixels, let inspection {
                    HStack(alignment: .top, spacing: 8) {
                        pixelReadout("A", inspection.a, information: pixelA?.colorInformation)
                        pixelReadout("B", inspection.b, information: pixelB?.colorInformation)
                    }
                    if let a = inspection.a, let b = inspection.b {
                        Text("Relative RGBA difference: \(PixelColorConversion.relativeDifference(a, b), specifier: "%.3f")")
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("Values are converted to 8-bit sRGB for comparison; wide-gamut and HDR detail may be clipped.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text("Align B to A")
                    Picker("Anchor", selection: $anchor) {
                        ForEach(ImageAnchor.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .frame(width: 155)
                    .disabled(alignedImageB != nil)
                    TextField("X", value: $offsetX, format: .number)
                        .frame(width: 58)
                        .accessibilityLabel("Horizontal alignment offset in pixels")
                        .disabled(alignedImageB != nil)
                    TextField("Y", value: $offsetY, format: .number)
                        .frame(width: 58)
                        .accessibilityLabel("Vertical alignment offset in pixels")
                        .disabled(alignedImageB != nil)
                    Button("Auto Align") { autoAlign() }
                        .disabled(autoAligning || sizeA == nil || sizeB == nil)
                    Button("Perspective Align") { perspectiveAlign() }
                        .disabled(autoAligning || sizeA == nil || sizeB == nil)
                    Button("Reset") {
                        anchor = .topLeft
                        offsetX = 0
                        offsetY = 0
                        clearPerspectiveAlignment()
                    }
                    .disabled(anchor == .topLeft && offsetX == 0 && offsetY == 0 && alignedImageB == nil)
                    if autoAligning { ProgressView().controlSize(.small) }
                    Spacer()
                }
                HStack(spacing: 10) {
                    if let alignmentError {
                        Text(alignmentError).foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if alignedImageB != nil {
                        Text("Perspective preview of B in A's space; Save As exports the original source.")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Perspective preview of B in A's space; Save As exports the original source.")
                            .accessibilityIdentifier("perspective-alignment-preview")
                    }
                    Spacer()
                    Text("Output")
                    Picker("Output image", selection: $selectedOutput) {
                        ForEach(OutputSide.allCases, id: \.self) { side in
                            Text(side.rawValue).tag(side)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 72)
                    Button("Save As…") { saveSelectedImage() }
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            GeometryReader { geometry in
                Group {
                    if let canvas {
                        switch mode {
                        case .twoUp:
                            HStack(spacing: 2) {
                                picture(.a, canvas: canvas)
                                picture(.b, canvas: canvas)
                            }
                        case .oneUp:
                            picture(showingLeft ? .a : .b, canvas: canvas)
                        case .split:
                            ZStack {
                                picture(.b, canvas: canvas)
                                picture(.a, canvas: canvas)
                                    .mask(alignment: .leading) {
                                        Rectangle().frame(width: geometry.size.width * split)
                                    }
                            }
                        case .difference:
                            if let mask, let image = maskImage(mask) {
                                ZStack {
                                    picture(showingLeft ? .a : .b, canvas: canvas)
                                    maskPicture(image, canvas: canvas)
                                        .opacity(opacity)
                                }
                            } else if let maskError {
                                ContentUnavailableView(maskError, systemImage: "photo.badge.exclamationmark")
                            } else {
                                ProgressView("Calculating pixel differences…")
                            }
                        }
                    } else {
                        ContentUnavailableView("Image dimensions unavailable", systemImage: "photo.badge.exclamationmark")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    guard inspectPixels, !inspectionLocked else { return }
                    inspect(at: value.location, canvas: geometry.size)
                })
                .onContinuousHover { phase in
                    guard inspectPixels, !inspectionLocked else { return }
                    switch phase {
                    case .active(let location): inspect(at: location, canvas: geometry.size)
                    case .ended: break
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showNavigator, let canvas {
                        navigator(canvas: canvas, mainSize: geometry.size)
                            .padding(12)
                    }
                }
                .onAppear { viewportSize = geometry.size }
                .onChange(of: geometry.size) { _, size in viewportSize = size }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            if let savedOutput {
                Text("Saved \(savedOutput.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .task {
            if imageA == nil { imageA = NSImage(contentsOf: left) }
            if imageB == nil { imageB = NSImage(contentsOf: right) }
            if sizeA == nil { sizeA = try? ImageSize.load(left) }
            if sizeB == nil { sizeB = try? ImageSize.load(right) }
        }
        .task(id: differenceTaskID) {
            guard mode == .difference else { return }
            mask = nil
            maskError = nil
            let a = left
            let b = right
            let selectedMode = differenceMode
            let selectedColor = maskColor
            let selectedThreshold = threshold
            let selectedTranslation = translation
            let selectedAlignedData = alignedImageData
            let worker = Task.detached(priority: .userInitiated) {
                if let selectedAlignedData {
                    try PixelDifference.compare(left: a, rightData: selectedAlignedData,
                                                mode: selectedMode, threshold: selectedThreshold,
                                                maskColor: selectedColor)
                } else {
                    try PixelDifference.compare(left: a, right: b,
                                                mode: selectedMode, threshold: selectedThreshold,
                                                maskColor: selectedColor,
                                                translation: selectedTranslation)
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if !Task.isCancelled { mask = result }
            } catch {
                if !Task.isCancelled { maskError = error.localizedDescription }
            }
        }
        .task(id: "\(inspectPixels):\(alignmentVersion)") {
            guard inspectPixels else {
                pixelA = nil
                pixelB = nil
                inspection = nil
                inspectionLocked = false
                return
            }
            loadingPixels = true
            pixelLoadError = nil
            let a = left
            let b = right
            let selectedAlignedData = alignedImageData
            let worker = Task.detached(priority: .userInitiated) {
                (try PixelBuffer.load(a), try selectedAlignedData.map(PixelBuffer.load(data:))
                    ?? PixelBuffer.load(b))
            }
            do {
                let buffers = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if !Task.isCancelled {
                    pixelA = buffers.0
                    pixelB = buffers.1
                }
            } catch {
                if !Task.isCancelled { pixelLoadError = error.localizedDescription }
            }
            loadingPixels = false
        }
        .alert("Image Save Error", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: zoom) { _, _ in clampPan() }
    }

    private func maskImage(_ mask: PixelDifferenceMask) -> NSImage? {
        guard let provider = CGDataProvider(data: mask.rgba as CFData),
              let image = CGImage(width: mask.width, height: mask.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: mask.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    .union(.byteOrder32Big),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: mask.width, height: mask.height))
    }

    private func picture(_ side: OutputSide, canvas: ImageCanvas) -> some View {
        GeometryReader { geometry in
            let image = side == .a ? imageA : (alignedImageB ?? imageB)
            let size = side == .a ? sizeA : (alignedImageB == nil ? sizeB : sizeA)
            let originX = side == .a ? canvas.leftX : canvas.rightX
            let originY = side == .a ? canvas.leftY : canvas.rightY
            let fit = min(geometry.size.width / CGFloat(canvas.width),
                          geometry.size.height / CGFloat(canvas.height))
            Group {
                if let image, let size {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(size.width) * fit,
                               height: CGFloat(size.height) * fit)
                        .position(x: geometry.size.width / 2 +
                                      CGFloat(originX * 2 + size.width - canvas.width) * fit / 2,
                                  y: geometry.size.height / 2 +
                                      CGFloat(originY * 2 + size.height - canvas.height) * fit / 2)
                } else {
                    ContentUnavailableView("Cannot Open Image", systemImage: "photo.badge.exclamationmark")
                }
            }
        }
        .scaleEffect(zoom)
        .offset(x: pan.width + drag.width, y: pan.height + drag.height)
        .clipped()
    }

    private func maskPicture(_ image: NSImage, canvas: ImageCanvas) -> some View {
        GeometryReader { geometry in
            let fit = min(geometry.size.width / CGFloat(canvas.width),
                          geometry.size.height / CGFloat(canvas.height))
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(canvas.width) * fit,
                       height: CGFloat(canvas.height) * fit)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .scaleEffect(zoom)
        .offset(x: pan.width + drag.width, y: pan.height + drag.height)
        .clipped()
    }

    private func autoAlign() {
        autoAligning = true
        alignmentError = nil
        let a = left
        let b = right
        Task {
            let worker = Task.detached(priority: .userInitiated) {
                try ImageRegistration.translation(left: a, right: b)
            }
            do {
                let result = try await worker.value
                clearPerspectiveAlignment()
                anchor = .topLeft
                offsetX = result.x
                offsetY = result.y
            } catch {
                alignmentError = error.localizedDescription
            }
            autoAligning = false
        }
    }

    private func perspectiveAlign() {
        autoAligning = true
        alignmentError = nil
        let a = left
        let b = right
        Task {
            let worker = Task.detached(priority: .userInitiated) {
                try ImageRegistration.perspectiveAligned(left: a, right: b)
            }
            do {
                let result = try await worker.value
                guard let image = NSImage(data: result) else {
                    throw PixelDifferenceError.renderingFailed
                }
                alignedImageData = result
                alignedImageB = image
                anchor = .topLeft
                offsetX = 0
                offsetY = 0
                inspection = nil
                pixelB = nil
                alignmentVersion = UUID()
            } catch {
                alignmentError = error.localizedDescription
            }
            autoAligning = false
        }
    }

    private func clearPerspectiveAlignment() {
        alignedImageData = nil
        alignedImageB = nil
        inspection = nil
        pixelB = nil
        alignmentVersion = UUID()
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($drag) { value, state, _ in
                if zoom > 1 { state = value.translation }
            }
            .onEnded { value in
                guard zoom > 1 else { return }
                pan.width += value.translation.width
                pan.height += value.translation.height
                clampPan()
            }
    }

    private func viewportGeometry(canvas: ImageCanvas, size: CGSize) -> ImageViewport {
        let width = mode == .twoUp ? max(1, (size.width - 2) / 2) : max(1, size.width)
        return ImageViewport(canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height),
                             viewportWidth: Double(width), viewportHeight: Double(max(1, size.height)),
                             zoom: zoom)
    }

    private func clampPan() {
        guard let canvas, viewportSize != .zero else { return }
        let limited = viewportGeometry(canvas: canvas, size: viewportSize)
            .clampedPan(x: Double(pan.width), y: Double(pan.height))
        pan = CGSize(width: limited.x, height: limited.y)
    }

    private func navigator(canvas: ImageCanvas, mainSize: CGSize) -> some View {
        let scale = min(160 / CGFloat(canvas.width), 120 / CGFloat(canvas.height))
        let width = CGFloat(canvas.width) * scale
        let height = CGFloat(canvas.height) * scale
        let viewport = viewportGeometry(canvas: canvas, size: mainSize)
        let rect = viewport.visibleRect(panX: Double(pan.width + drag.width),
                                        panY: Double(pan.height + drag.height))
        return ZStack(alignment: .topLeading) {
            Color(nsColor: .controlBackgroundColor)
            if let image = showingLeft ? imageA : (alignedImageB ?? imageB),
               let size = showingLeft ? sizeA : (alignedImageB == nil ? sizeB : sizeA) {
                let originX = showingLeft ? canvas.leftX : canvas.rightX
                let originY = showingLeft ? canvas.leftY : canvas.rightY
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(size.width) * scale,
                           height: CGFloat(size.height) * scale)
                    .position(x: (CGFloat(originX) + CGFloat(size.width) / 2) * scale,
                              y: (CGFloat(originY) + CGFloat(size.height) / 2) * scale)
            }
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .frame(width: CGFloat(rect.width) * scale,
                       height: CGFloat(rect.height) * scale)
                .position(x: CGFloat(rect.x + rect.width / 2) * scale,
                          y: CGFloat(rect.y + rect.height / 2) * scale)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.7)))
        .shadow(radius: 4)
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in
            let targetX = min(Double(canvas.width), max(0, Double(value.location.x / scale)))
            let targetY = min(Double(canvas.height), max(0, Double(value.location.y / scale)))
            let next = viewport.panToCenter(x: targetX, y: targetY)
            pan = CGSize(width: next.x, height: next.y)
        })
        .accessibilityLabel("Image navigator for \(showingLeft ? "A" : "B")")
        .accessibilityHint("Drag to move the shared image viewport")
    }

    private func pixelReadout(
        _ label: String, _ sample: PixelSample?, information: ImageColorInformation?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let sample {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: Double(sample.red) / 255,
                                    green: Double(sample.green) / 255,
                                    blue: Double(sample.blue) / 255)
                            .opacity(Double(sample.alpha) / 255))
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary))
                    Text("\(label) (\(sample.x), \(sample.y)) \(sample.hex)")
                }
                Text(PixelColorConversion.components(of: sample, in: colorFormat)
                    .map { "\($0.name) \(String(format: "%.1f", $0.value))\($0.unit)" }
                    .joined(separator: "    "))
                    .font(.system(.caption, design: .monospaced))
                Text("Alpha \(sample.alpha) · \(information?.sourceDepth ?? 8)-bit \(information?.sourceModel ?? "unknown") · \(information?.sourceProfile ?? "unspecified")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(label) outside image")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func inspect(at location: CGPoint, canvas: CGSize) {
        guard let pixelA, let pixelB, let imageCanvas = self.canvas,
              canvas.width > 0, canvas.height > 0 else {
            inspection = nil
            return
        }
        let paneWidth: CGFloat
        let paneOrigin: CGFloat
        switch mode {
        case .twoUp:
            paneWidth = (canvas.width - 2) / 2
            let onRight = location.x >= paneWidth + 2
            paneOrigin = onRight ? paneWidth + 2 : 0
        case .oneUp, .difference:
            paneWidth = canvas.width
            paneOrigin = 0
        case .split:
            paneWidth = canvas.width
            paneOrigin = 0
        }
        let fit = min(paneWidth / CGFloat(imageCanvas.width),
                      canvas.height / CGFloat(imageCanvas.height))
        let displayedWidth = CGFloat(imageCanvas.width) * fit * zoom
        let displayedHeight = CGFloat(imageCanvas.height) * fit * zoom
        let centerX = paneOrigin + paneWidth / 2 + pan.width + drag.width
        let centerY = canvas.height / 2 + pan.height + drag.height
        let x = Int(floor((location.x - centerX + displayedWidth / 2) / (fit * zoom)))
        let y = Int(floor((location.y - centerY + displayedHeight / 2) / (fit * zoom)))
        let a = pixelA.sample(pixelX: x - imageCanvas.leftX,
                              pixelY: y - imageCanvas.leftY)
        let b = pixelB.sample(pixelX: x - imageCanvas.rightX,
                              pixelY: y - imageCanvas.rightY)
        guard a != nil || b != nil else {
            inspection = nil
            return
        }
        inspection = ImageInspection(a: a, b: b)
    }

    private func saveSelectedImage() {
        let source = selectedOutput == .a ? left : right
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        if let type = UTType(filenameExtension: source.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != left.standardizedFileURL,
              destination.standardizedFileURL != right.standardizedFileURL else {
            saveError = "Choose a separate output file to preserve both source images."
            return
        }
        do {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            if FileManager.default.fileExists(atPath: destination.path) {
                let expected = try Data(contentsOf: destination, options: .mappedIfSafe)
                _ = try SafeTextWrite.replace(at: destination, expected: expected, with: data)
            } else {
                try SafeTextWrite.create(at: destination, data: data)
            }
            savedOutput = destination
        } catch {
            saveError = error.localizedDescription
        }
    }
}

