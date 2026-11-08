# Mac Diff Studio agent guidance

- This is an independent Swift 6/macOS 27 application. Do not inspect,
  decompile, copy, or redistribute proprietary Kaleidoscope internals or assets.
- Keep application behavior and acceptance tests aligned with
  `docs/capability-checklist.md`; mark only demonstrated outcomes complete.
- Preserve input bytes on read-only paths. Merges and folder copies must use
  explicit destinations, previews, and atomic replacement or recovery paths.
- Keep source content local. Network use is limited to updates.
- Run `swift test` and the Xcode app build after code changes.
- Do not commit or publish without the user asking for that action.

