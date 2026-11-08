import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor final class VellographUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWelcomeAndFilePickerCanOpenAndCancel() {
        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launch()

        let openButton = app.buttons["Open Files or Folders…"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))
        openButton.click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
    }

    func testOpenTwoTextFilesAndNavigateChange() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("same\nold\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("same\nnew\n".utf8).write(to: folder.appendingPathComponent("b.txt"))

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launch()
        openFixtureFolder(folder, in: app)

        XCTAssertTrue(app.staticTexts["1 changes"].waitForExistence(timeout: 10))
        let next = app.buttons["Next"]
        XCTAssertTrue(next.exists)
        next.click()
    }

    func testImageModesAndDifferenceCount() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writePNG([255, 0, 0, 255, 255, 0, 0, 255],
                     to: folder.appendingPathComponent("a.png"))
        try writePNG([255, 0, 0, 255, 0, 0, 255, 255],
                     to: folder.appendingPathComponent("b.png"))

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launch()
        openFixtureFolder(folder, in: app)

        for mode in ["One Up", "Split", "Difference", "Two Up"] {
            let button = app.radioButtons[mode]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.click()
            XCTAssertEqual((button.value as? NSNumber)?.intValue, 1)
            if mode == "Difference" {
                XCTAssertTrue(app.staticTexts["1 of 2 pixels differ"].waitForExistence(timeout: 10))
            }
        }
    }

    func testPerspectiveAlignmentCanBeReset() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = folder.appendingPathComponent("a.png")
        let floating = folder.appendingPathComponent("b.png")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Artwork/VellographIcon-master.png"), to: reference)
        let size = 1254
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = CIImage(contentsOf: reference)
        filter.topLeft = CGPoint(x: -5, y: size + 7)
        filter.topRight = CGPoint(x: size + 11, y: size + 2)
        filter.bottomLeft = CGPoint(x: -10, y: -3)
        filter.bottomRight = CGPoint(x: size + 3, y: -13)
        guard let warped = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: size, height: size)),
              let data = CIContext().pngRepresentation(of: warped, format: .RGBA8,
                                                        colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            throw NSError(domain: "VellographUITests", code: 4)
        }
        try data.write(to: floating)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launch()
        openFixtureFolder(folder, in: app)
        let align = app.buttons["Perspective Align"]
        XCTAssertTrue(align.waitForExistence(timeout: 10))
        align.click()
        let preview = app.staticTexts["perspective-alignment-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["Horizontal alignment offset in pixels"].isEnabled)
        app.buttons["Reset"].click()
        XCTAssertFalse(preview.exists)
        XCTAssertTrue(app.textFields["Horizontal alignment offset in pixels"].isEnabled)
    }

    func testThreeWayConflictRequiresAChoice() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("same\nbase\n".utf8).write(to: folder.appendingPathComponent("0-base.txt"))
        try Data("same\nlocal\n".utf8).write(to: folder.appendingPathComponent("1-local.txt"))
        try Data("same\nremote\n".utf8).write(to: folder.appendingPathComponent("2-remote.txt"))

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launch()
        openFixtureFolder(folder, in: app)
        let confirm = app.buttons["Confirm Roles"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let baseRole = app.popUpButtons.element(boundBy: 0)
        baseRole.click()
        app.menuItems["0-base.txt"].click()
        XCTAssertEqual(baseRole.value as? String, "0-base.txt")
        XCTAssertEqual(app.popUpButtons.element(boundBy: 2).value as? String, "2-remote.txt")
        confirm.click()
        XCTAssertTrue(app.staticTexts["0 of 1 conflicts resolved"].waitForExistence(timeout: 10))
        let build = app.buttons["Build Output"]
        XCTAssertFalse(build.isEnabled)
        app.typeKey("2", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["1 of 1 conflicts resolved"].waitForExistence(timeout: 5))
        XCTAssertTrue(build.isEnabled)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])
        let output = app.textViews["Merged output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertTrue((output.value as? String)?.contains("remote") == true,
                      "Actual merged output: \(String(describing: output.value))")
        app.typeKey("s", modifierFlags: [.command])
        let saveDialog = app.dialogs.firstMatch
        XCTAssertTrue(saveDialog.waitForExistence(timeout: 5))
        saveDialog.buttons["Save"].click()
        let saved = folder.appendingPathComponent("1-local.txt.merged")
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "same\nremote\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("1-local.txt"),
                                  encoding: .utf8), "same\nlocal\n")
    }

    func testStagedBinaryGitChangeCannotResolveAsText() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        let repository = folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try runGit(in: repository, ["init", "-q"])
        let item = repository.appendingPathComponent("binary.dat")
        try Data([0, 1, 2, 3]).write(to: item)
        try runGit(in: repository, ["add", "--", "binary.dat"])
        try runGit(in: repository, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                                    "-c", "user.email=test@example.invalid", "commit", "-qm", "baseline"])
        try Data([0, 1, 2, 4]).write(to: item)
        try runGit(in: repository, ["add", "--", "binary.dat"])

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launch()
        openFixtureFolder(folder, in: app)
        let staged = app.buttons["Staged"]
        XCTAssertTrue(staged.waitForExistence(timeout: 10))
        staged.click()
        let resolve = app.buttons["Resolve…"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 10))
        XCTAssertFalse(resolve.isEnabled)
    }

    private func openFixtureFolder(_ folder: URL, in app: XCUIApplication) {
        app.buttons["Open Files or Folders…"].click()
        XCTAssertTrue(app.dialogs["Open"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.dialogs["Open"].buttons["Open"].click()
    }

    private func writePNG(_ pixels: [UInt8], to url: URL) throws {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 2, height: 1, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    .union(.byteOrder32Big), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "VellographUITests", code: 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "VellographUITests", code: 2)
        }
    }

    private func runGit(in directory: URL, _ arguments: [String]) throws {
        let process = Process()
        let configuredDeveloperDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("usr/bin/git") }
        let applicationCandidates = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
            .map { $0.appendingPathComponent("Contents/Developer/usr/bin/git") } ?? []
        guard let executable = ([configuredDeveloperDirectory].compactMap { $0 } + applicationCandidates)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NSError(domain: "VellographUITests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Xcode's Git executable was not found."])
        }
        process.executableURL = executable
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "VellographUITests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }
}
