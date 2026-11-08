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

    func testRecentComparisonRestoresAndMissingSourceReportsError() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        let suite = "io.github.michaeldadi.vellograph.ui-test.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let left = folder.appendingPathComponent("a.txt")
        let right = folder.appendingPathComponent("b.txt")
        try Data("old\n".utf8).write(to: left)
        try Data("new\n".utf8).write(to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launchEnvironment["VELLOGRAPH_UI_TEST_SUITE"] = suite
        try launchWithFixtures([left, right], in: app)
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))
        app.buttons["Show welcome"].click()
        XCTAssertTrue(app.staticTexts["Recent Comparisons"].waitForExistence(timeout: 5))
        let recent = app.buttons.matching(NSPredicate(
            format: "label MATCHES %@", "^(a\\.txt ↔ b\\.txt|b\\.txt ↔ a\\.txt)$"
        )).firstMatch
        XCTAssertTrue(recent.exists)
        recent.click()
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "VELLOGRAPH_UI_TEST_PATHS")
        app.launch()
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))
        app.terminate()
        try FileManager.default.removeItem(at: right)
        app.launch()
        XCTAssertTrue(app.staticTexts["Recent Comparisons"].waitForExistence(timeout: 10))
        recent.click()
        XCTAssertTrue(app.staticTexts["Unable to Open"].waitForExistence(timeout: 10))
    }

    func testShelfOrderRenameSelectionAndRestoration() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        let suite = "io.github.michaeldadi.vellograph.ui-test.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let left = folder.appendingPathComponent("a.txt")
        let right = folder.appendingPathComponent("b.txt")
        try Data("a\n".utf8).write(to: left)
        try Data("b\n".utf8).write(to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        app.launchEnvironment["VELLOGRAPH_UI_TEST_SUITE"] = suite
        try launchWithFixtures([left, right], in: app, seedShelf: true)

        let labels = app.textFields.matching(identifier: "Source label")
        XCTAssertEqual(labels.count, 2)
        let first = labels.element(boundBy: 0).value as? String
        app.buttons["Move Down"].firstMatch.click()
        XCTAssertNotEqual(labels.element(boundBy: 0).value as? String, first)
        labels.element(boundBy: 0).click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Renamed")
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        XCTAssertEqual(labels.element(boundBy: 0).value as? String, "Renamed")
        app.buttons["Select Renamed as A"].click()
        app.buttons["Select Renamed as B"].click()
        XCTAssertFalse(app.buttons["Compare A/B"].isEnabled)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "VELLOGRAPH_UI_TEST_PATHS")
        app.launchEnvironment.removeValue(forKey: "VELLOGRAPH_UI_TEST_SEED_SHELF")
        app.launch()
        let restored = app.textFields.matching(identifier: "Source label")
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.element(boundBy: 0).value as? String, "Renamed")
        app.buttons["Remove"].firstMatch.click()
        XCTAssertEqual(app.textFields.matching(identifier: "Source label").count, 1)
    }

    func testOpenTwoTextFilesAndNavigateChange() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = folder.appendingPathComponent("a.txt")
        let right = folder.appendingPathComponent("b.txt")
        try Data("same\nold\n".utf8).write(to: left)
        try Data("same\nnew\n".utf8).write(to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([left, right], in: app)

        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))
        let next = app.buttons["Next"]
        XCTAssertTrue(next.exists)
        next.click()
    }

    func testImageModesAndDifferenceCount() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = folder.appendingPathComponent("a.png")
        let right = folder.appendingPathComponent("b.png")
        try writePNG([255, 0, 0, 255, 255, 0, 0, 255], to: left)
        try writePNG([255, 0, 0, 255, 0, 0, 255, 255], to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([left, right], in: app)

        let window = app.windows.firstMatch
        let navigator = app.buttons["Navigator"]
        let actualPixels = app.buttons["Actual Pixels"]
        XCTAssertTrue(navigator.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(navigator.frame.maxX, window.frame.maxX - 8)
        XCTAssertLessThanOrEqual(actualPixels.frame.maxX, navigator.frame.minX)
        XCTAssertLessThanOrEqual(app.buttons["Perspective Align"].frame.maxX,
                                 window.frame.maxX - 8)

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
        try launchWithFixtures([reference, floating], in: app)
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
        let base = folder.appendingPathComponent("0-base.txt")
        let local = folder.appendingPathComponent("1-local.txt")
        let remote = folder.appendingPathComponent("2-remote.txt")
        try Data("same\nbase\n".utf8).write(to: base)
        try Data("same\nlocal\n".utf8).write(to: local)
        try Data("same\nremote\n".utf8).write(to: remote)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([base, local, remote], in: app)
        let confirm = app.buttons["Confirm Roles"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let baseRole = app.popUpButtons.element(boundBy: 0)
        baseRole.click()
        app.menuItems["0-base.txt"].click()
        XCTAssertEqual(baseRole.value as? String, "0-base.txt")
        XCTAssertEqual(app.popUpButtons.element(boundBy: 2).value as? String, "2-remote.txt")
        confirm.click()
        XCTAssertTrue(app.staticTexts["0 of 1 conflict resolved"].waitForExistence(timeout: 10))
        let build = app.buttons["Build Output"]
        XCTAssertFalse(build.isEnabled)
        app.typeKey("2", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["1 of 1 conflict resolved"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Saved 1-local.txt.merged"].waitForExistence(timeout: 10))
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
        try launchWithFixtures([repository], in: app)
        let staged = app.buttons["Staged"]
        XCTAssertTrue(staged.waitForExistence(timeout: 10))
        staged.click()
        let resolve = app.buttons["Resolve…"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 10))
        XCTAssertFalse(resolve.isEnabled)
    }

    func testGitHistoryRevisionsAndInvalidReference() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        let repository = folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try runGit(in: repository, ["init", "-q"])
        let file = repository.appendingPathComponent("guide.txt")
        try Data("first\n".utf8).write(to: file)
        try runGit(in: repository, ["add", "--", "guide.txt"])
        try runGit(in: repository, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                                    "-c", "user.email=test@example.invalid", "commit", "-qm", "baseline"])
        try Data("second\n".utf8).write(to: file)
        try runGit(in: repository, ["add", "--", "guide.txt"])
        try runGit(in: repository, ["-c", "commit.gpgsign=false", "-c", "user.name=Test",
                                    "-c", "user.email=test@example.invalid", "commit", "-qm", "change"])
        try Data("working\n".utf8).write(to: file)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([repository], in: app)
        XCTAssertTrue(app.staticTexts["1 of 1 changed item"].waitForExistence(timeout: 10))

        app.radioButtons["History"].click()
        let commit = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Commit change,"
        )).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 10))
        commit.click()
        XCTAssertTrue(app.staticTexts["1 changed file"].waitForExistence(timeout: 10))
        app.buttons["File History"].click()
        XCTAssertTrue(app.staticTexts["File History · guide.txt"].waitForExistence(timeout: 10))
        app.buttons["Done"].click()

        app.radioButtons["Compare Revisions"].click()
        app.buttons["Compare Revisions"].click()
        let changes = app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "1 of 1 change"
        )).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 10))

        let from = app.textFields["From revision"]
        from.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("does-not-exist")
        app.buttons["Compare Revisions"].click()
        XCTAssertTrue(app.staticTexts["Unable to Open"].waitForExistence(timeout: 10))
    }

    func testFolderPreviewCopyAndStaleClonePreserveDestination() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        let left = folder.appendingPathComponent("left")
        let right = folder.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = left.appendingPathComponent("changed.txt")
        let destination = right.appendingPathComponent("changed.txt")
        let destinationOnly = right.appendingPathComponent("only-right.txt")
        let hidden = right.appendingPathComponent(".keep-hidden")
        try Data("new\n".utf8).write(to: source)
        try Data("old\n".utf8).write(to: destination)
        try Data("original\n".utf8).write(to: destinationOnly)
        try Data("hidden\n".utf8).write(to: hidden)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([left, right], in: app)
        XCTAssertTrue(app.staticTexts["2 differences"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(app.buttons["Preview Clone"].frame.maxX, window.frame.maxX - 8)
        XCTAssertLessThanOrEqual(app.textFields["Filter paths"].frame.maxX, window.frame.maxX - 8)
        XCTAssertLessThanOrEqual(app.buttons["Clear Selection"].frame.maxX, window.frame.maxX - 8)
        XCTAssertLessThanOrEqual(app.textFields["Ignore path regex (one per line)"].frame.maxX,
                                 window.frame.maxX - 8)
        app.buttons["Pause Live Updates"].click()
        app.buttons["Select Visible Differences"].click()
        app.buttons["Preview Copy Selected"].click()
        XCTAssertTrue(app.staticTexts["Review Copy Selected"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].click()
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old\n")

        app.buttons["Preview Copy Selected"].click()
        XCTAssertTrue(app.staticTexts["Review Copy Selected"].waitForExistence(timeout: 10))
        app.buttons["Apply Reviewed Changes"].click()
        XCTAssertTrue(app.staticTexts["1 difference"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new\n")
        XCTAssertEqual(try String(contentsOf: destinationOnly, encoding: .utf8), "original\n")

        app.buttons["Preview Clone"].click()
        XCTAssertTrue(app.staticTexts["Review Clone Visible Scope"].waitForExistence(timeout: 10))
        try Data("external edit\n".utf8).write(to: destinationOnly)
        app.buttons["Apply Reviewed Changes"].click()
        XCTAssertTrue(app.staticTexts["Folder Operation Failed"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: destinationOnly, encoding: .utf8), "external edit\n")
        XCTAssertEqual(try String(contentsOf: hidden, encoding: .utf8), "hidden\n")
    }

    func testTextLiveRefreshCanPauseAndResume() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = folder.appendingPathComponent("a.txt")
        let right = folder.appendingPathComponent("b.txt")
        try Data("same\n".utf8).write(to: left)
        try Data("same\n".utf8).write(to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([left, right], in: app)
        XCTAssertTrue(app.staticTexts["0 changes"].waitForExistence(timeout: 10))

        try Data("changed while watching\n".utf8).write(to: right, options: .atomic)
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))
        app.buttons["Pause Live Updates"].click()
        XCTAssertTrue(app.buttons["Resume Live Updates"].exists)
        try Data("same\n".utf8).write(to: right, options: .atomic)
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(app.staticTexts["1 change"].exists)

        app.buttons["Resume Live Updates"].click()
        XCTAssertTrue(app.staticTexts["0 changes"].waitForExistence(timeout: 10))
        try Data("intermediate\n".utf8).write(to: right, options: .atomic)
        try Data("final state\n".utf8).write(to: right, options: .atomic)
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "value CONTAINS %@", "final state"
        )).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: left, encoding: .utf8), "same\n")
    }

    func testTwoWayResolutionKeyboardUndoAndSafeSave() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = folder.appendingPathComponent("a.txt")
        let right = folder.appendingPathComponent("b.txt")
        let leftText = "first A\nshared one\nshared two\nsecond A\n"
        let rightText = "first B\nshared one\nshared two\nsecond B\n"
        try Data(leftText.utf8).write(to: left)
        try Data(rightText.utf8).write(to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([left, right], in: app)
        XCTAssertTrue(app.staticTexts["2 changes"].waitForExistence(timeout: 10))
        app.buttons["Resolve…"].click()
        let build = app.buttons["Build Output"]
        XCTAssertTrue(build.waitForExistence(timeout: 5))
        XCTAssertFalse(build.isEnabled)
        XCTAssertTrue(app.buttons["Use B for next unresolved change"].exists)
        app.typeKey("2", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["1 of 2 chosen"].waitForExistence(timeout: 5))
        app.typeKey("4", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["2 of 2 chosen"].waitForExistence(timeout: 5))
        app.typeKey("z", modifierFlags: [.command])
        XCTAssertTrue(app.staticTexts["1 of 2 chosen"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: [.command])
        XCTAssertTrue(build.isEnabled)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command, .shift])
        let output = app.textViews["Resolved text output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertEqual(output.value as? String,
                       "first B\nshared one\nshared two\nsecond A\n")

        app.typeKey("s", modifierFlags: [.command])
        let saveDialog = app.dialogs.firstMatch
        XCTAssertTrue(saveDialog.waitForExistence(timeout: 5))
        saveDialog.buttons["Save"].click()
        let saved = folder.appendingPathComponent("b.txt.resolved")
        XCTAssertTrue(app.staticTexts["Saved b.txt.resolved"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8),
                       "first B\nshared one\nshared two\nsecond A\n")
        XCTAssertEqual(try String(contentsOf: left, encoding: .utf8), leftText)
        XCTAssertEqual(try String(contentsOf: right, encoding: .utf8), rightText)
    }

    func testTextLayoutsWhitespaceAndMissingSourceRefresh() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellograph-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = folder.appendingPathComponent("a.txt")
        let right = folder.appendingPathComponent("b.txt")
        try Data("alpha  beta\n".utf8).write(to: left)
        try Data("alpha beta\n".utf8).write(to: right)

        let app = XCUIApplication()
        app.launchEnvironment["VELLOGRAPH_UI_TESTING"] = "1"
        try launchWithFixtures([left, right], in: app)
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))
        for layout in ["Fluid", "Unified", "Blocks"] {
            let control = app.radioButtons[layout]
            control.click()
            XCTAssertEqual((control.value as? NSNumber)?.intValue, 1)
        }
        app.menuButtons["Compare Options"].click()
        app.menuItems["Ignore Whitespace"].click()
        XCTAssertTrue(app.staticTexts["0 changes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Resolve…"].isEnabled)
        app.menuButtons["Compare Options"].click()
        app.menuItems["Ignore Whitespace"].click()
        XCTAssertTrue(app.staticTexts["1 change"].waitForExistence(timeout: 10))

        app.buttons["Pause Live Updates"].click()
        try FileManager.default.removeItem(at: right)
        app.buttons["Refresh"].click()
        XCTAssertTrue(app.staticTexts["Comparison Error"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: left, encoding: .utf8), "alpha  beta\n")
    }

    private func launchWithFixtures(_ urls: [URL], in app: XCUIApplication,
                                    seedShelf: Bool = false) throws {
        let paths = urls.map(\.path)
        let data = try JSONEncoder().encode(paths)
        app.launchEnvironment["VELLOGRAPH_UI_TEST_PATHS"] = String(decoding: data, as: UTF8.self)
        if seedShelf { app.launchEnvironment["VELLOGRAPH_UI_TEST_SEED_SHELF"] = "1" }
        app.launch()
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
