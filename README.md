# Mac Diff Studio

An independent, native macOS 27 diff and merge application. The project is
under active development; the [capability checklist](docs/capability-checklist.md)
tracks what is implemented and tested.

## Build

Requires an Apple Silicon Mac with Xcode 27 and XcodeGen.

```sh
xcodegen generate
xcodebuild -project MacDiffStudio.xcodeproj -scheme MacDiffStudio -configuration Debug build
swift test
```

The application is an original implementation. It does not include code,
resources, or branding from Kaleidoscope.

