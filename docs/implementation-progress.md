# Implementation progress — 2026-11-08

This is a development checkpoint. The release contract remains
[`capability-checklist.md`](capability-checklist.md); none of its full workflow
items is qualified yet. The evidence below distinguishes checked-in changes,
local use, hosted CI, and release qualification.

## Implemented and exercised on this Mac

- The native app opens file, folder, image, and Git repository comparisons in
  tabs. Two-pane text now clips at each pane boundary and scrolls horizontally.
  The welcome view now separates recent repositories from recent comparisons.
  After installing a newer local build and relaunching, the prior comparison
  tabs and selected image pair reopened. Image view controls reset to their
  defaults; full session-state qualification remains open.
- The app now has a custom Dock icon in `App/Assets.xcassets/AppIcon.appiconset`.
  The built bundle declares `AppIcon`, contains `AppIcon.icns`, and its 16-,
  32-, and 256-pixel renderings were visually checked. See `icon-artwork.md`.
- Text diff has Blocks, Fluid, and Unified displays, word changes, search,
  change navigation, whitespace and line-ending options, JSON normalization,
  ordered filters, patch export, two-way resolution, and print/PDF export.
  A disposable PDF exported through the UI contained the expected text.
  Snapshot tests now cover UTF-8 BOM, both UTF-16 byte orders, mixed line
  endings, Unicode, empty input, NUL binary input, and malformed UTF-8.
- Text views now detect common source languages or allow a manual choice, with
  Adaptive, Vivid, and Monochrome syntax themes. Coloring is bounded to files
  at most 1 MiB and lines at most 20,000 UTF-16 units. The native app showed
  Swift keywords and strings in color, then switched to Monochrome.
  A bounded lexical pass now tracks Swift and JavaScript block comments, XML
  comments, Python and Swift triple-quoted strings, and JavaScript templates
  across lines. It keeps comment markers inside strings from turning into
  comments. Five scanner tests pass. In the installed app, a six-line Swift
  fixture and a 3,005-line virtualized fixture showed the comment across
  lines in gray, while code following it retained keyword and string colors.
  The selected theme is stored as an app preference, including when navigating
  between files in a Git changeset. This lightweight coloring is not a full
  language parser; raw strings and embedded languages remain open.
- Comparisons above 2,000 display rows use reusable AppKit table cells. A
  16,384-line pair scrolls without the prior SwiftUI layout stall, and a
  163,840-line, 9.27 MiB pair opens and jumps to its changed line in the native
  app. A 4,000-line Swift fixture retained syntax and changed-word colors in
  that virtual view. Wrapping and precise first-viewport timing remain open.
  A fresh native screenshot at the 900-point minimum window width showed
  unwrapped text clipped at the pane divider without drawing into the other
  pane.
- Three-way text merge presents conflicts, requires choices, permits editing,
  and saves through a checked replacement or exclusive create path.
- PDF and Word text extraction is supported. Binary or unsupported content
  opens metadata, Quick Look, and a bounded-memory exact byte comparison.
- Image comparison has the four basic views and an absolute or proportional
  pixel mask. A View Mode menu now advertises Command–Option–1 through 4 for
  the four modes; all four changed the active mode in the installed app.
  The image view now saves the chosen A or B bytes through a checked
  destination and keeps decoded previews for the lifetime of the view. A native
  Save As check produced a byte-identical copy of a disposable PNG. Shared
  zoom/pan and Fit controls are implemented; zoom and Fit were exercised in the
  native app. Pixel inspection shows paired coordinates, color swatches, and
  channel values, with a lock control. A click on disposable images displayed
  both samples. Nine manual image anchors, X/Y offsets, and Vision translation
  registration now use one canvas for the overlay, mask, and inspector. On a
  shifted 128-pixel fixture, Auto Align found X=8/Y=-5; the visible difference
  count fell from 7,064 to 3,248, and aligned A/B samples matched. Pan/lock
  edge cases and larger image performance remain open.
  Difference masks now offer red, magenta, cyan, and yellow, with a native
  screenshot check of the two-row controls and yellow overlay. A navigator now
  displays the shared viewport and permits direct repositioning. At 400% zoom,
  dragging its viewport rectangle moved both image panes and the rectangle to
  the new location in the installed app; Fit restored the original view.
  Actual Pixels uses the display's physical pixel length; the native 32-pixel
  fixture was visually checked at 32 screen pixels. In the installed Debug
  build, a disposable 4096 × 4096 PNG pair opened in Two Up, completed its
  Difference mask (12,396,772 of 16,777,216 pixels), switched to Actual
  Pixels, displayed the navigator, and returned to Fit. The app showed zero
  idle CPU and about 275 MiB resident memory immediately after this check.
  This was a manual functional check; release-mode latency, scrolling, and
  larger-image memory gates remain open.
- The pixel inspector now retains the last sample after the pointer leaves an
  image. RGB, HSB, HSL, and Lab values and a normalized RGBA difference were
  checked in the native UI on disposable images. The source profile, model,
  and bit depth are shown. Inspector samples are color-managed into 8-bit sRGB;
  wide-gamut and HDR detail can be clipped and remains outside release parity.
- Folder comparison has filters, reviewed copy/clone plans, and recovery of
  replaced items. Copying one nested item now includes its missing ancestor
  folders in the preview. Stage and recovery directories are siblings of the
  destination, and each destination is fingerprinted again immediately before
  its action. Tests cover nested copy with hidden files enabled and a changed
  destination after preview. Clone now preserves hidden or ignored children and
  their containing directories. Empty directory removal uses an atomic `rmdir`,
  and a hidden file arriving after preview causes rollback of earlier actions;
  temporary-directory tests cover both. Copy and clone refuse to modify a
  macOS package directory such as `.app`; a disposable package test passes.
  A plan records each root folder's resolved path, device, and inode, then
  rechecks them before staging and each action. Replacing a destination root
  with an identical-looking directory is rejected in a disposable test.
  Relative symbolic links now resolve through any intermediate links in both
  the source and destination trees before copy. The preview and apply phases
  reject a link that would escape either root, including a destination link
  chain changed after preview. Three disposable folder tests cover those
  cases; the package suite and signed app build pass. Fully race-free
  filesystem operations still require more work.
  A final-check race test now changes a destination file immediately before
  its backup move. The copy compares the recovered bytes with the preview and
  restores that external edit without installing the source. This narrows the
  replacement race. A second final-check test swaps an existing destination
  parent for a link to an outside folder; the recheck rejects it and leaves
  the outside file unchanged. Destination actions and rollback now use open
  directory descriptors and exclusive renames. Disposable tests swap a parent
  for an outside link or an identical-looking directory after the descriptor
  opens; both leave outside or replacement content untouched and restore the
  original. A new file arriving after preview is preserved, and a destination
  replaced with identical bytes but a different inode is restored rather than
  accepted as the previewed item. Rollback also keeps a later external file
  with identical bytes and retains the original in recovery for manual review.
  A permission failure on a later nested replacement rolls back an earlier
  successful replacement. Stage and recovery folders have mode 0700.
  Staging still uses path-based copying. Crash recovery, same-directory entry
  swaps during empty-directory removal, and broader failure-injection remain
  open; these tests do not qualify folder mutation as fully race-free. The full
  Swift package suite and Release app build pass locally with this change.
- FSEvents refreshes text, folder, and Git views; pause/resume was exercised
  with disposable files in the native app.
- A private Unix socket connects the `vellograph` CLI to the app, with
  same-user peer checks. `diff`, `diff --wait`, and an explicit-output `merge`
  were exercised in the native app. Git changeset and working-copy commands
  opened the expected views. Closing an unresolved CLI merge returned status 1
  and left no output. Stdin snapshots use private files that are removed on
  tab close and on a failed request. Invalid Git revisions now return status 2
  before creating a tab. Core socket and safe-write tests pass.
- `vellograph://` now parses local compare, history, and changeset links with
  exact query validation. The parser tests cover encoded paths and reject
  remote sources, extra fields, and duplicate revision parameters. Safari
  delivered a `history` link to the locally signed installed development build,
  and the native app opened the repository with History selected. See
  `url-scheme.md` for the remaining host-app routes.
- The app bundle advertises a Finder Services command named “Compare with
  Vellograph” for selected file URLs. Its provider accepts one or two local
  items and opens the comparison in the app. The generated bundle property
  list and Xcode build were verified. `NSPerformService` delivered two
  disposable file URLs through the registered service and opened their
  comparison in the running app. The Finder context menu now shows the
  installed app's “Compare with Vellograph” Service after unregistering two
  disposable update-test app copies from Launch Services. Invoking it on two
  disposable text files opened a one-change comparison in the installed app;
  the test tab and files were removed. The Action extension is also visible as
  a Quick Action in that menu.
- A separate read-only Action extension is embedded for local file, folder,
  and image comparisons in a host app. It presents a bounded quick preview and
  lets the user choose a second item when the host supplies only one. The first
  installed build was rejected by PlugInKit because the extension was not
  sandboxed. The extension now has an App Sandbox entitlement with read-only
  access to user-selected files; the signed Xcode build passes. Finder's
  extension setting was enabled, and a duplicate registration from DerivedData
  was removed. Finder's Preview pane then showed the Action for images. Finder
  provided `public.png` image content instead of a file URL; the extension now
  copies bounded content into its private temporary directory before the host
  removes its representation. In the installed build, a single selected image
  opened the chooser and then showed both image previews. The temporary copy
  was removed on Done. Adding text activation support made the Action visible
  for two selected text files; its preview showed the expected one-line change
  and addition. Finder did not offer the Action for a selected folder pair;
  Finder Services and the Share extension remain the folder entry points.
  The source-copy path now reads at most 25 MB even if a host item grows after
  the metadata check, writes the private snapshot with mode 0600, and removes
  it after the preview. The updated extension builds and was installed locally.
  Finder supplied a disposable 64 MiB TIFF through the Action; the hosted view
  displayed the intended size-limit guidance, and its private snapshot folder
  was empty after Done. In a separate Finder-hosted Action check, a single
  disposable text item opened the second-item chooser. Its private snapshot
  was moved before selecting the second item; the view reported that one of
  the selected items was no longer available. Done removed the private
  snapshot directory. This checks a stale snapshot after host handoff; a
  provider that fails to deliver its item remains untested.
- A separate Share extension uses the same read-only preview and sandbox
  permissions. It builds, registers with PlugInKit, and appears in Finder's
  Share sheet. Selecting two disposable text files opened its hosted view and
  displayed the expected one-line unified diff. Sharing one text file showed a
  second-item prompt. Its original modeless Open panel appeared behind Finder's
  modal Share dialog; the chooser now attaches as a sheet. Selecting a second
  disposable file then displayed the expected one-line diff. Finder also
  displayed two image previews and reported one changed file for a disposable
  folder pair. A mixed folder and Swift file pair showed the expected
  same-kind guidance. In Finder, moving a disposable text file after the Share
  extension accepted its URL and then selecting a second item produced the
  no-longer-available message. Sharing a 5,000,001-byte text file with a small
  second file showed the quick-preview size limit and directed the user to the
  full app. Other hosts and provider-delivery failures still need checks.
- A macOS App Intents action named “Compare Local Files” accepts one or two
  local file URLs and opens the same workspace workflow. Its metadata was
  generated by Xcode; after installing a locally signed development build,
  the action appeared in Shortcuts and opened two disposable files from a
  test shortcut. Shortcut input from Finder-selected files and invalid-input
  feedback still need checks. The test shortcut has blank inputs and is named
  “Compare in Vellograph” in the user's Shortcuts library.
- An optional menu bar drop helper is implemented with an AppKit status item
  and SwiftUI popover. The first dropped item can wait for a second; dropping
  two items opens a comparison directly. A SwiftUI `MenuBarExtra` version
  caused an app-graph startup loop on macOS 27.2, so it was replaced. The
  AppKit version launches normally and sits at zero idle CPU in this check;
  the Settings toggle was exercised on and off. Direct popover and drag/drop
  interaction were initially unverified. The Settings button did not show its
  status-item popover on this Mac. It now presents the same drop view as a
  SwiftUI popover attached to the button. The installed signed build visibly
  showed "Drop files to compare", "Open Files…", and "Show App" after clicking
  it, and Escape dismissed it. The helper was left off in settings. Direct
  menu bar activation and drag/drop remain unverified. Its "Open Files…"
  control opened the native chooser, which was canceled without changing any
  source. "Show App" initially left Settings in front; it now raises the
  existing workspace window, or opens one when needed. The installed build
  visibly returned to the workspace after this action. The helper setting was
  returned to off after each check.
- Git worktree discovery passed a temporary linked-worktree test. The native
  Worktrees menu opened the detached checkout from a disposable repository.
- Git tree, index, and working-copy reads now distinguish file blobs from
  submodule commit pointers. A disposable local submodule test covers the
  committed, indexed, and advanced working pointer without fetching a remote.
  Git text tabs display the pointer and explain that submodule files are not
  included. Binary Git blobs display exact byte count and SHA-256; a canonical
  Git LFS pointer is labeled without fetching its large object. Temporary
  repository tests cover the pointer and exact binary bytes. In the installed
  signed build, a disposable revision changeset opened the submodule pointer,
  two distinct binary SHA-256 summaries, and the before/after LFS pointers
  with the expected size and no-fetch explanation. Text resolution is disabled
  for those presentations, so a saved text result cannot be mistaken for an
  edited submodule, binary blob, or LFS object.
- Git history now draws commit lanes and labels branch, remote, and tag tips.
  Revision comparison offers ref menus alongside free-form revision fields.
  A disposable merge history with an annotated tag passed graph and ref tests;
  the native history graph and ref menu were visually checked. Selecting a
  remote ref updated the comparison field in the native app.
- Git working-copy and revision changesets now support path search, status or
  change-kind filters, and expandable directory outlines. A path-tree test
  covers nested paths and a file/directory collision. The native working-copy
  outline was filtered to one nested file, expanded, and the revision outline
  displayed the three-file HEAD~1-to-HEAD changeset. A revision file comparison
  now has previous/next file controls and Command–Option–Arrow shortcuts. The
  native app advanced through all three files within one tab, including the
  keyboard shortcut and disabled end control.
- Unmerged Git paths now open their stage 1/2/3 text in the three-way resolver.
  A native test on a disposable conflicted repository saved the selected side
  to the working file, retained the prior conflict-marked file in recovery,
  and left Git's index unmerged for explicit staging. Binary and add/delete
  conflicts now open a separate whole-file choice view. The core tests cover
  exact binary bytes, choosing a deleted side, recovery, stale index rejection,
  and leaving the index unmerged. A native binary-conflict check selected
  Theirs, saved the three-byte file, showed a recovery path, and left all
  three Git index stages unmerged. A native delete/modify check selected the
  deleted Ours side, removed the working file, retained its previous bytes in
  recovery, and left both index stages unmerged. Richer binary previews and
  other conflict variants remain open.
- An existing merge output changed after opening the CLI merge was rejected
  by the native Save Output action. The external edit remained intact and the
  CLI exited with status 1 after the tab closed.
- A local text comparison now offers an Open Source menu for each file, using
  the default app or a chosen app. The chosen-app workflow opened the actual
  `AGENTS.md` source in TextEdit; the diff stayed open in Vellograph.
- Snapshot directory ownership and mode are checked before accepting stdin.
  On startup, the app removes only Vellograph-named, regular snapshots older
  than one hour; a temporary-directory test covers stale versus recent files.
- Clipboard text and image data now become private shelf sources. Temporary
  sources can be saved to a separate file and are deleted when no tab or shelf
  entry references them. Startup cleanup removes old orphaned clipboard files
  while preserving restored sources. Focused file-mode and cleanup tests pass.
  In the installed app, a two-line text clipboard fixture appeared on the
  shelf, and Save As produced the expected 38 bytes in a mode-0600 file. The
  clipboard fixture was then removed from the system clipboard.
- The diff engine now keeps matching prefixes and suffixes around a large
  unmatched segment. A 31,000-line repeated-text regression test confirms
  that an unchanged file stays unchanged and one edited line stays one hunk.
  Cancellation is now checked while building comparison keys, finding patience
  anchors, creating coarse operations, and assembling hunks. A cancelled-task
  regression test passes. A bound on the unmatched search area now turns two
  unrelated 2,000-line blocks into one coarse hunk; that case has a regression
  test. The release text probe still completed its 9.27 MiB diff in 0.171
  seconds on this Mac.
- `vellograph git-tool` can preview, install, and uninstall repository-local or
  global difftool/mergetool settings. It saves prior values in a private backup
  and refuses to replace settings edited afterward. Disposable Git tests
  confirmed both difftool and mergetool pass the expected files and output
  paths to the configured executable. See `git-tool-setup.md`; installed-app
  verification now confirms that its preview uses
  `~/Applications/Vellograph.app/Contents/Helpers/vellograph`.
- `integration-recipes.md` now records local CLI, editor, launcher, Safari, and
  Jujutsu templates. Only the Git tool and Safari URL workflows have host
  checks; the other host templates remain unqualified.
- The Xcode app target now embeds a separate `vellograph` executable in
  `Contents/Helpers`. The installed development bundle passed deep code-signature
  verification, its bundled command returned help, and that command opened a
  disposable two-file comparison in the installed app. A bundle verification
  script checks that the GUI and CLI remain distinct arm64 executables; the
  local CI workflow runs it after the app build. A clean unsigned Release build
  also passed the bundle check: the GUI and helper are distinct arm64 Mach-O
  executables. Signed release packaging and Homebrew linking remain open.
- The renamed Vellograph Sparkle proof updated 0.2.0 to 0.2.1 on this Mac;
  `update-proof.md` records the remaining release checks.
- A release-mode core probe measured line parsing, diffing, display-row
  construction, a 100,000-entry folder comparison, and a 4096 × 4096 image
  difference on this Mac. The reproducible icon-based image probe took 0.421
  seconds and the probe process peaked at 287 MB resident memory. See
  `performance-baseline.md`. App viewport and interaction performance still
  need instrumentation.
- A release-mode 5000 × 5000 PNG pair completed the full pixel difference in
  0.861 seconds with a 420 MB process peak. An 8192 × 8192 pair was rejected
  by the current 25-million-pixel limit. The difference and both registration
  paths now check encoded dimensions before full decode. A 262 KB, 8192 × 8192
  PNG fixture was rejected in a core test; a release-mode rejection peaked at
  10.8 MB of process memory. See `performance-baseline.md`; app-level latency
  and bounded-memory support above that limit remain open.
- `.github/workflows/macos-ci.yml` now defines read-only PR, main-branch, and
  weekly package tests plus an unsigned Xcode app build on the `xcode-27`
  runner. Scheduled and manual runs also record the core text, folder, and
  image performance probes. The hosted `build-and-test` job passed on commit
  `bab77b6` (run `42473717947`). Its timing output remains observational
  until runner baselines are measured.
- An Xcode UI test target now isolates session preferences and IPC during its
  launch. Local XCUITest checks passed for the welcome screen and native file
  picker, opening a two-file text fixture and navigating its change, and
  opening two PNGs and switching through all four image modes. The Difference
  mode reported the expected one changed pixel. A three-file merge fixture
  confirmed that output stays disabled until its conflict is chosen, then
  exposes editable output. A staged binary Git change displayed a read-only
  summary with text resolution disabled. All five UI tests passed together on
  this Mac. Save, drag/drop, accessibility, and
  appearance checks remain open.
- The merge view now exposes Command–1 through 4 for Local, Remote, Both, and
  Neither on the next unresolved conflict, plus Command–Shift–Return to build
  output. Its role pickers and quick-choice buttons have explicit accessibility
  labels. A native UI test assigned the three source roles after Finder returned
  the selected files in reverse order, chose Remote and built output using only
  keyboard shortcuts, and confirmed the output contained the remote text.
  The full five-case UI suite passed again. The same focused test then saved
  output through the native Save dialog, verified the saved bytes, and confirmed
  that the local source remained unchanged. The Save dialog now starts beside
  the local source file. Keyboard operation across multiple conflicts and a
  full VoiceOver review remain open.
- The installed `vellograph` command returned status 2 for a missing input,
  missing merge base, repeated stdin marker, and unknown option without
  creating a comparison. These are local CLI failure checks, not a complete
  exit-code or transport test.
- The CLI now rejects repeated value options, including a repeated merge
  output. `scripts/verify-cli-failures.sh` checks seven invalid requests for
  status 2, a diagnostic, and no merge output. It passes for the signed app
  installed in `~/Applications` and is included in the local macOS CI workflow.
  Cancellation, transport failure, and host integration exit codes still need
  complete workflow checks.
- Vision-based perspective alignment now warps image B into A's pixel space
  for preview, difference masks, and pixel inspection. Reset restores the
  original image; manual offsets are disabled while a perspective preview is
  active. A warped icon fixture reduced changed pixels by more than 20% in a
  repeatable core test, and a native UI test verified the preview and Reset.
  The seven-case native UI suite and all Swift package tests passed after this
  change, and the signed app bundle passed verification before installation
  in `~/Applications`.
  This does not establish reliability on arbitrary photographs or large
  images; those remain open image acceptance cases.
- The image toolbar now has separate mode and zoom rows at the minimum window
  width. A native UI test checked that Actual Pixels, Navigator, and
  Perspective Align stay within the window without crossing each other. The
  installed app's two-up image view was also visually checked at that width.
- Native UI tests now use a separate preference suite, leaving the real app's
  recent comparisons and shelf untouched. A test reopened a recent text pair,
  restored its selected tab after relaunch, then removed a source and confirmed
  the welcome view showed an error when reopening that stale recent item.
- Another isolated native UI test added two files to the source shelf, moved
  their order, renamed one with the keyboard, disabled comparison by selecting
  the same entry as A and B, and confirmed the order and label survived a
  relaunch before removing an entry. Clipboard save, drag/drop, and full
  keyboard navigation still need direct tests.
- The installed `vellograph diff --wait` held its process until its disposable
  comparison tab was closed, then returned status 0. An unresolved CLI merge
  closed without output returned status 1 and created no file. Repeating that
  merge, choosing Remote in the native app, building, and saving the requested
  output returned status 0; the output bytes matched Remote and both source
  files stayed unchanged. Transport-failure behavior still needs a complete
  installed-app workflow.
- Git's actual `mergetool` host invoked the installed Vellograph command for
  a disposable text conflict. Closing its unresolved tab made Git report a
  failed merge and kept all three unmerged index stages. Repeating the host
  invocation, selecting Remote, and saving `conflict.txt` returned success,
  wrote the expected bytes, and cleared the index conflict. Repository-local
  tool settings were then uninstalled and read back as absent.
- The CLI now launches Vellograph only when its private socket is absent or
  stale. An insecure directory or non-socket path fails immediately, and
  non-waiting commands have a 30-second response timeout. IPC package tests
  covered missing, unsafe, and silent sockets. All Swift package tests, the
  signed Xcode build, bundle verification, and the seven invalid-command
  checks passed after the change. The installed bundled CLI was later exercised
  against an unsafe regular file at the app's socket path and a private
  same-user socket that accepted but never replied. Both valid `diff` requests
  returned status 2 with an error and no stdout; the latter timed out as
  intended. The pre-existing stale socket was restored after the disposable
  fixtures, and the relaunched app published a connectable socket. The
  interrupted-response and wrong-user cases remain open.
- A later eight-case Xcode UI rerun was interrupted when macOS logged a user
  gesture that stopped Automation Mode during the image fixture. The resulting
  loss of accessibility authorization affected the remaining cases. The
  earlier focused and full passes remain recorded above; this latest rerun is
  not a passing release gate.
- A separate `native-ui` job invokes the eight Xcode UI tests on the hosted
  macOS 27 runner with parallel UI execution disabled. Its first run failed;
  `xcodebuild -quiet` did not include the failing assertion in the job log.
  The workflow now prints the `.xcresult` summary and retains the result bundle
  for a failed run. The result bundle showed that the hosted file picker
  selected 165 runner-directory items instead of the two fixture files after
  its Go to Folder action. The downstream UI tests now receive explicit,
  disposable fixture paths through a test-only launch environment; the
  separate welcome test still opens and cancels the native file picker.
  Swift package tests and the signed Xcode build pass. The revised hosted
  macOS 27 run `42476617751` passed both `build-and-test` and `native-ui` at
  commit `4da6bd3`. Local UI automation remains unauthorized after the macOS
  Automation Mode interruption.
- A signed Release-configuration app build passed bundle checks for the GUI,
  CLI, Action extension, and Share extension, plus deep code-signature
  verification. It uses an Apple Development identity. No valid Developer ID
  Application identity is installed, so this is not a notarized public build.
- A ninth hosted native UI case opened a disposable repository, showed its
  working-copy change, selected a commit and file history, compared `HEAD~1`
  with `HEAD`, and checked the invalid-revision alert. The first assertion
  queried the revision summary's accessibility label even though macOS exposed
  its value; the result bundle showed one change on screen. The corrected
  nine-case `native-ui` job and the parallel build-and-test job passed at
  commit `121b229`.
- Folder controls now occupy two rows at the 900-point minimum window width.
  A tenth hosted native case passed toolbar bounds, preview cancel, selected
  copy while retaining destination-only content, and rejection of a destination
  edit made after clone preview. The full hosted run `42478704178` passed both
  jobs at commit `2f409c0`. The installed signed Debug app now includes these
  changes and passed bundle and signature readback. A local screenshot exposed
  the Direction picker label wrapping at the minimum window width, so its
  redundant visible label was hidden; the installed app's toolbar was then
  visually checked again. The follow-up hosted run `42479394167` passed both
  jobs at commit `4377a46`.
- An eleventh hosted native UI case exercised the text layout choices, a
  whitespace-only difference changing from one to zero with Ignore Whitespace,
  and an error after the source was removed and Refresh was requested. Singular
  change, conflict, file, and difference counts were corrected across the UI.
  The hosted run `42479949299` passed both jobs at commit `657b939`.
  Local Swift package tests and a signed Xcode test build passed. The signed
  Debug app installed in `~/Applications` includes these changes; bundle and
  deep signature checks passed, and it launched afterward.
- A twelfth native UI case is prepared for text FSEvents refresh, pause/resume,
  and two rapid edits that should display the final file contents. The Swift
  package suite and signed Xcode test build passed locally. Its first hosted
  run failed the live-refresh assertion. A direct installed-app check found
  that FSEvents reports canonical `/private/tmp` paths for files opened through
  `/tmp`, while the view filtered events using the original `/tmp` path. The
  monitor now reports both canonical paths and the original watched aliases.
  A standalone FSEvents probe showed both path forms. In the installed signed
  build, a file edit updated the text without manual Refresh, Pause held the
  old result, Resume caught up, and two rapid edits displayed the final text.
  The first hosted execution of the corrected watcher displayed the final
  text in the accessibility tree and passed the other eleven native cases, but
  the new test queried the text element's label instead of its value. That
  assertion has been corrected. The next hosted `native-ui` run passed all
  twelve cases at commit `8ec8498` (run `42483235046`); its build-and-test job
  also passed.
- A hosted run after the workspace-focus change passed the build job but had
  one native UI failure: the three-way merge test read its output file before
  the Save action had visibly completed. The test now waits for the app's
  "Saved" confirmation before checking the exact output bytes. That corrected
  merge workflow passed in the twelve-case hosted run `42483235046`.
- The published Vellograph appcast matched the checked-in copy byte-for-byte.
  Sparkle 2.10.1's `sign_update --verify` accepted both, and rejected a copy
  with a changed title. The app now opts into signed-feed validation and
  verification of update archives before extraction. A signed Release build
  passed bundle, code-signature, and both Info.plist flag checks. In-app
  final-package tamper/offline checks and public signing remain open. A public-key verifier
  now checks the appcast signature and both built-app settings in CI; it passed
  locally against the signed feed and rejected a changed copy. The verified
  signed Release app was installed in `~/Applications` after a guarded backup
  and launched with the prior workspace session intact.
- A local `vellograph://diff` URL opened the expected one-change comparison.
  With the earlier build, SwiftUI created another workspace window; the open
  workspace now declares that it accepts external URLs. After installing the
  signed Release build, the same URL opened a tab in the existing window and
  left one app process and one IPC listener. The disposable comparison tab was
  closed afterward. A link to a missing absolute file showed the native
  "Unable to Open" alert without adding a comparison tab.
- An isolated, re-signed copy of the installed Release app used a separate
  bundle ID and loopback feed. With no server, the in-app check reported a
  retrieval error. It rejected a feed with a changed signed byte, then offered
  an update from a correctly signed local feed and rejected its archive after
  one byte was changed. The copy stayed at bundle version 4 with a valid code
  signature; the local server was stopped and the installed app resumed its
  previous tabs. See `update-proof.md`. The final distribution package still
  needs these checks and Developer ID signing.
- Two-way text resolution now offers Command–1 through 4 choices for the next
  unresolved change, Command–Z choice undo, Command–Shift–Return to build, and
  Command–S to save. Save As starts beside the source. The first run of the
  thirteenth hosted UI case reached Save but queried a path macOS truncated in
  its accessibility value. The confirmation now shows the filename and keeps
  the full path in its tooltip. The corrected hosted run `42486536194` passed
  all 13 cases, including keyboard choices across two changes, undo, exact
  saved output, and unchanged inputs. Package tests and a signed local Xcode
  test build also passed. The installed Release app now includes this change.
- A release-mode Git probe now creates a disposable 5,000-file repository with
  1,125 changed paths. Repository open took 0.346 seconds and three status
  calls took 0.112, 0.108, and 0.117 seconds on this Mac; the process peaked
  at 14.5 MB resident memory including fixture creation. The weekly CI job
  now records the same probe. App-level Git interaction timing remains open.
- Large image display geometry is now separate from the 25-million-pixel
  full-resolution difference limit. An 8192 × 8192 PNG pair can use the basic
  image views; Difference builds a reduced-resolution ImageIO preview and
  labels its count as sampled pixels, not an exact source-resolution count.
  The first thumbnail implementation peaked at 715 MB in the release probe.
  Switching to ImageIO subsampling cut that to 165 MB for a changed PNG/JPEG
  pair while producing a 4096² preview in 1.602 seconds. The full Swift test
  suite and signed Release build pass. In the installed app, Two Up showed the
  two 8192² sources and Difference reported 0 of 16,777,216 sampled pixels
  for an identical pair. The disposable tab was closed and the previous app
  kept in a guarded backup. Full-resolution large differences, pixel
  inspection, and alignment remain open. The first hosted 14-case native UI
  run failed only because the new test's fixture path included `Tests/Tests`.
  After correcting the path, run `42507506471` passed all 14 native cases and
  its build-and-test job.
- The IPC server now awaits its async request handler without blocking a
  dispatch worker on a semaphore. It records the socket inode created by
  bind and unlinks only that socket at shutdown; a test replaced the path
  with a regular file and verified that stopping the server preserved the
  replacement. The full Swift package suite and signed Release build passed.
  After a guarded install, the bundled CLI opened a disposable two-file diff
  in the running app, which showed the expected one-change result. The test
  tab and files were removed. Hosted run `42508584298` passed both jobs at
  commit `7187cd6`, including all 14 native UI cases. A new core test uses a
  private same-user Unix socket whose peer reads the request and closes before
  replying; the client returns `invalidMessage` promptly. The full Swift
  package suite and signed Release build pass locally with that test. Hosted
  run `42509914277` passed both jobs at commit `112074c`. A real app-process
  interruption and wrong-user peer workflow remain open.
- Session restore now reports how many saved comparisons it skipped when a
  source file has disappeared. The existing native restore test checks that
  message before reopening the comparison from Recents and checking its error.
  Hosted run `42510180595` passed its build job and the other 13 UI cases;
  the new assertion expected one skipped tab, but the test had opened the same
  comparison twice before relaunch, so two tabs were saved. The failing run's
  screen recording showed the correct two-tab message. The assertion now checks
  for two skipped tabs. Hosted run `42510950730` passed both jobs at commit
  `ce2ada2`, including all 14 native UI cases and the folder parent-swap test.
- The workspace loading indicator now counts overlapping file and Git opens,
  so an earlier request finishing cannot hide progress while another is still
  running. The build passes locally; concurrent-request UI verification remains
  open.
- Folder destination writes and rollback now use pinned directory handles and
  exclusive renames, with the race and identity checks described above. The
  signed local Release build was installed and reopened with the prior tabs.
  Hosted macOS 27 run `42513435760` at `c92ff06` passed both build-and-test
  and native-ui jobs. A later permission-failure rollback test passes locally;
  hosted run `42514153875` at `7f0f66b` passed both jobs.
- `OSSignposter` intervals now mark comparison loading, image preparation,
  and explicit image difference calculation. The signed installed Release app
  was captured with Xcode's Logging template on macOS 27.2. A single 8.9 MiB
  per-side text pair loaded in 692.69 ms; the 4096² image pair prepared in
  13.73 ms and calculated its exact difference in 439.71 ms. The native app
  showed one text change and 12,621,444 changed image pixels. These are
  operation intervals, not first-frame or scrolling measurements; see
  `performance-baseline.md`. The full Swift package suite and signed Release
  build passed locally after the instrumentation change.
- The installed app also opened a changed 8192² PNG pair. Difference mode
  rendered its mask and explicitly labeled 12,614,169 of 16,777,216 pixels as
  sampled preview differences. The Xcode Logging trace recorded 225.17 ms to
  open the comparison, 21.11 ms to prepare the image view, and 1.14 seconds to
  calculate the sampled difference. The disposable tab was closed. First-frame,
  scrolling, and peak app-memory measurements remain open.
- Opening many comparisons could leave the newly selected tab outside the
  visible tab strip. Selection now scrolls to its tab after SwiftUI has laid
  out the strip. The Home button stays visible beside the scrolling tabs,
  and Command–Shift–H opens Welcome. A signed native UI test opens twelve
  disposable comparison pairs, verifies the last tab and Home button are
  hittable, and uses the shortcut to reach Welcome. It passed locally on
  macOS 27.2. The test inputs are removed afterward. Hosted run `42517366685`
  passed both jobs at `facb873` before the fixed Home button was added.

## Next verification and implementation

1. Finish the extensions' provider-delivery and other-host failure checks,
   app-level large-image performance checks, and remaining CLI failure workflows.
2. Complete the remaining text, image, folder, Git, workspace, and integration
   outcomes in the capability checklist; test keyboard and failure paths.
3. Repeat the update failure and rollback checks on final packaging, finish
   performance and uninterrupted UI gates, then validate the Homebrew cask.

Run `swift test` and the Xcode app build after code changes. Keep status as
implemented, locally exercised, or release-qualified rather than treating
those as equivalent.
