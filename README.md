# Vellograph

An independent, native macOS 27 diff and merge application. The project is
under active development; the [capability checklist](docs/capability-checklist.md)
tracks what is implemented and tested. The [implementation plan](docs/implementation-plan.md)
sets the remaining work and release gates.

## Build

Requires an Apple Silicon Mac with Xcode 27 and XcodeGen.

```sh
xcodegen generate
xcodebuild -project Vellograph.xcodeproj -scheme Vellograph -configuration Debug build
swift test
```

On this Mac, run the native UI smoke tests after generating the project:

```sh
xcodebuild -project Vellograph.xcodeproj -scheme Vellograph \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:VellographUITests test
```

The application is an original implementation. It does not include code,
resources, or branding from Kaleidoscope.

Local editor, launcher, VCS, and Safari entry points are described in
[integration recipes](docs/integration-recipes.md).

