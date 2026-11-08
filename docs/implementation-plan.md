# Vellograph implementation plan

Updated 2026-11-08. Target: an independent, fast, native macOS 27 diff and
merge app that covers the observable outcomes in
[the capability checklist](capability-checklist.md). The checklist is the
acceptance contract; [implementation progress](implementation-progress.md)
records evidence already obtained. This plan describes remaining work and the
order in which to close it. It does not assume access to Kaleidoscope code,
assets, private APIs, or undocumented implementation details.

## Product and release rules

- Ship an original Swift 6/AppKit/SwiftUI app for Apple Silicon and macOS 27.
  Preserve local content on the user's Mac. Network access is for app updates.
- Treat a visible feature, a passing core test, a passing native workflow, and
  a distributable release as separate claims. A checklist item closes only
  after normal, keyboard, failure, and repeatable macOS 27 checks pass.
- Read-only comparison must never change its sources. Any merge, copy, clone,
  or resolve operation needs an explicit destination, a preview where content
  could be replaced, a stale-source check, and a recovery path.
- Offer a useful, honest error for unsupported content or limits. The current
  25-million-pixel full-resolution difference cap is a known limitation, not
  a completed large-image workflow.
- Release only with a clean install and update path. The current 0.2.1
  prerelease proves update mechanics with development signing; it is not the
  public release or a parity claim.

## Architecture and change boundaries

| Area | Owner in repository | Boundary |
| --- | --- | --- |
| Native workspace | `App/` | Tabs, source shelf, focused commands, native accessibility, platform integrations |
| Text comparison | `Sources/DiffCore/`, `Sources/SyntaxCore/`, `Sources/DocumentCore/` | Parsing, comparison, bounded syntax scan, extraction, safe writes |
| Images | `Sources/ImageCore/` | Pixel normalization, registration, masks, viewport geometry |
| Folders | `Sources/FolderCore/` | Scan, preview, filesystem safety, staged apply and recovery |
| Git | `Sources/GitCore/` | Read Git state and objects without remote fetch or repository mutation |
| CLI and URLs | `Sources/IPCBridge/`, `Sources/VellographCLI/` | Validated local requests, same-user IPC, wait/exit contract |
| OS hosts | `Extensions/`, `App/ShortcutsIntents.swift`, `App/MenuBarController.swift` | Bounded, read-only host input; launch main app only for full workflow |
| Packaging | `project.yml`, `.github/workflows/`, `scripts/`, `docs/appcast.xml` | Signed, verified app, CLI, extensions, updater, and rollback |

Keep platform UI on the main actor and expensive scans/diffs off it. Pass
immutable results into views. Preserve cancellation and bound work before
allocating decoded images or building huge displays. Generated Xcode project
changes originate in `project.yml` and are reviewed together.

## Work sequence

### 1. Data safety and bounded performance

1. Replace path-only folder mutations with directory-descriptor operations
   (`openat`/`fstatat`/`renameat` or an equivalent) that refuse symlink traversal
   through every destination component. Revalidate source and destination
   identity immediately before each operation. Preserve external edits made
   between final validation and the move, and retain recovery if rollback
   cannot complete. Test symlink swaps, parent-directory swaps, permission
   failures, interrupted copy, clone deletion, packages, and ignored children.
2. Profile the **app** from request acceptance to visible first viewport, not
   only the core library. Cover cold and warm 1/10 MiB text pairs, 100,000
   folder entries, 5,000 tracked Git files with a busy worktree, and 4096² and
   8192² images. Record median and slowest of at least three runs, peak resident
   memory, idle CPU, and cancellation latency on this Mac and hosted macOS 27.
3. Keep a full-resolution image path for supported sizes. For larger images,
   use tiled/viewport rendering and bounded pixel inspection/difference work,
   or explicitly reject the operation before decoding if the measured budget
   cannot be met. Validate color profile and alpha behavior with fixtures.
4. Add performance thresholds to CI only after a stable hosted baseline is
   measured; investigate a regression before changing a threshold. A stalled
   spinner, unbounded memory growth, or a frozen window blocks release even if
   a core timing is fast.

### 2. Workspace and text workflows

1. Verify welcome recents, session restore, multiple tabs, drag/drop, clipboard,
   stdin, URLs, shelf ordering/selection/rename/save, and each path-bar action
   through both pointer and keyboard where the action exists. Test missing
   sources, a changed source during restore, cancel, and duplicate input.
2. Run a fixture matrix across UTF-8/UTF-16, BOMs, mixed line endings, empty
   inputs, binary/unsupported input, large repeated lines, JSON normalization,
   combined filters, syntax limits, and three display layouts. Check search,
   next/previous, word highlighting, synchronized scrolling, line numbers,
   wrapping, and invisibles in the native app.
3. Exercise two-way and three-way resolution with keyboard-only choices,
   undo, edit, save, cancel, and stale output. Verify exact destination bytes,
   unchanged inputs, unresolved exit status, and recovery after a failed save.
4. Qualify external editor, patch/clipboard, print/PDF, and PDF/Word extraction
   through real host workflows. Document extraction loss where source format
   cannot preserve layout or embedded content.

### 3. Image and folder workflows

1. Verify all four image modes, shortcuts, fit/actual/shared zoom, navigator,
   pan, split handle, alignment controls, absolute/proportional masks, color
   and opacity, pixel inspector lock, and source-preserving Save As. Use small
   exact fixtures plus photographs with and without valid perspective matches.
   Check image load failures, profile differences, transparency, and cancellation.
2. Verify folder hierarchy, filters, live refresh, nested comparison, Quick
   Look, metadata, selected copy, and clone preview with disposable trees.
   Check source-only, destination-only, hidden, ignored, symlink, package,
   permission, and externally edited paths. Compare source, destination, and
   recovery manifests after success and failure; never infer safety from a
   success banner alone.

### 4. Git and entry points

1. Cover staged, unstaged, partially staged, untracked, removed, renamed,
   binary, LFS-pointer, submodule, and unmerged paths in a disposable local
   repository. Compare commits, tags, branches, worktrees, and working copy;
   navigate the graph, file history, changeset outline and filters. Check
   FSEvents pause/resume, deleted worktree, invalid revision, and no network
   fetch. Compare every displayed blob or pointer with Git's exact object.
2. Test installed CLI commands and `vellograph://` requests, including stdin,
   snapshots, wait, all exit statuses, invalid options, interrupted response,
   unsafe socket, and wrong-user peer. Read back private temporary files and
   source bytes. Exercise actual Git difftool and mergetool hosts, then restore
   prior repository configuration.
3. Qualify Finder Service, Action, Share, Shortcuts, and menu-bar drop helper
   from their real hosts. Include one/two items, mixed kinds, missing provider
   content, oversized payload, canceled chooser, and repeated invocation.
   Confirm temporary copies are private and removed. Validate each documented
   editor/launcher/VCS recipe in its host or leave it labeled unverified.

### 5. Accessibility, appearance, and usability

1. Check minimum-width and full-screen layout, light/dark mode, larger text,
   high contrast, keyboard focus order, and VoiceOver descriptions in every
   view. Fix clipped controls and invisible focus. The Dock icon and current
   minimum-width text/image/folder layouts have local visual checks; repeat
   on the final app.
2. Verify actionable errors and progress for slow work, refresh, copy, merge,
   host extension, and update failures. Ensure canceled work does not publish
   a stale result. Preserve settings and open tabs across update/relaunch.

### 6. Public release and free updates

1. Confirm an installed **Developer ID Application** signing identity for the
   renewed Apple Developer account. Keep private signing and Sparkle EdDSA
   material outside the repository. Build the final arm64 app, embedded CLI,
   Action and Share extensions; verify every signature and entitlement.
2. Archive, notarize, staple, and validate the exact distribution artifact.
   Verify Gatekeeper launch on a clean macOS 27 installation. Publish release
   notes, archive, checksums, and a signed Sparkle feed over HTTPS. CI may
   verify public signatures; it must not expose private keys to PR jobs.
3. Install version N, update to N+1 in the app, then test offline feed,
   modified feed, modified archive, interrupted download, and rollback using
   the final package. Confirm the old version remains usable after each failed
   update and the installed version/CLI/extensions match after success.
4. Only then publish a Homebrew cask from the notarized artifact. In a clean
   environment verify `brew install`, GUI launch, CLI command, `brew upgrade`,
   `brew uninstall`, and removal of cask-owned files without deleting user
   comparisons or unrelated settings. Document the cask and manual install.
5. Review the draft pull request, record the tested commit and release hashes,
   merge, tag, and publish after release gates pass. Preserve a known-good
   archive and feed for rollback. Do not label the update-proof prerelease as
   stable.

## Verification cadence and evidence

- After a code change: `swift test --jobs 3`, an Xcode app build, the relevant
  focused native workflow, and `git diff --check`. CI runs package/build/feed
  checks and the native UI suite. A failed job needs its `.xcresult` or log
  inspected and a fresh hosted pass on the fix.
- For every checklist item, record a fixture and expected output, exact source
  and destination readback, keyboard/failure behavior, app/build version,
  local outcome, and hosted outcome in `implementation-progress.md`. Check the
  box only when all required evidence exists.
- Use disposable local fixtures. Restore any Git, Finder, Shortcuts, update,
  or app setting changed for verification. Keep guarded app backups until a
  verified release and rollback path replaces them.

## Known dependencies and release blockers

The current public repository and draft PR contain a broad implementation,
and hosted macOS 27 CI has passed 14 native UI cases. Those cases cover only
part of the checklist. Descriptor-safe folder mutation, larger image handling,
app-level performance gates, several real host integrations, and final-package
update tests remain. A Developer ID Application identity is not currently
installed on this Mac, so a notarized public release and Homebrew cask cannot
yet be validated. The renewed Apple Developer account may resolve that gate
once signing is configured; account renewal alone does not establish signing.
