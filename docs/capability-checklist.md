# Capability checklist — baseline 7.0.2

Baseline: documented Kaleidoscope 7.0.2 outcomes as of 2026-11-07. This is an
independent product specification, not a description of Kaleidoscope internals.
`[ ]` means incomplete, including when code exists but the workflow or test has
not passed. An item may be checked only after normal use, keyboard use, failure
handling, and a repeatable test pass on macOS 27.

## Workspace

Source: https://kaleidoscope.app/help/docs/starting-a-comparison and
https://kaleidoscope.app/help/docs/file-shelf

- [ ] Welcome window with recent comparisons and repository list; reopen each.
- [ ] Multiple tabbed comparisons, close/reopen, saved session state.
- [ ] Open files, folders, clipboard text/images, stdin, drag and drop, and URL requests.
- [ ] Ordered multi-item shelf; select A/B, swap, rename, remove, and save temporary content.
- [ ] Path bar with copy path, reveal in Finder, open in Terminal, and external open.

## Text and document extraction

Sources: https://kaleidoscope.app/help/docs/text-comparison-views,
https://kaleidoscope.app/help/docs/text-merging,
https://kaleidoscope.app/help/docs/text-compare-settings,
https://kaleidoscope.app/help/docs/text-filters, and
https://kaleidoscope.app/help/docs/sharing

- [ ] Accurate two-way line and word diff, including encodings and line endings.
- [ ] Blocks, Fluid, and Unified views with synchronized scrolling.
- [ ] Search, next/previous change, and navigation across a changeset.
- [ ] Syntax coloring with size limit, themes, line numbers, wrap, and invisibles.
- [ ] Whitespace modes, JSON normalization, and simultaneous custom text filters.
- [ ] Two-way copy A→B/B→A, both/none choice, undo, and safe save.
- [ ] Base-aware three-way merge and editable output; unresolved conflicts block success.
- [ ] Open in external editor; refresh changed files without losing work.
- [ ] Patch to file/clipboard, native print, PDF export, and share.
- [ ] Extract and compare PDF and Word text; explain extraction limitations.
- [ ] Binary/unsupported inputs show metadata and Quick Look without freezing.

## Images

Sources: https://kaleidoscope.app/help/docs/image-comparison-views,
https://kaleidoscope.app/help/docs/image-comparison-tools,
https://kaleidoscope.app/help/docs/pixel-comparison, and
https://blog.kaleidoscope.app/2026/02/26/kaleidoscope-6-6-ai-powered-alignment-for-screenshots-and-photos/

- [ ] Two Up, One Up, Split, and Difference views with shortcuts.
- [ ] Synchronized zoom/pan, adaptive/fit/actual modes, and image navigator.
- [ ] Manual translation, edge/corner anchors, and automatic content alignment.
- [ ] Perspective alignment where suitable for photographs.
- [ ] Absolute/proportional difference masks, colors, and opacity controls.
- [ ] Pixel inspector with lock, swatches, channel values, and color-space views.
- [ ] Resolve an image conflict by selecting A or B and saving output.

## Folders

Sources: https://kaleidoscope.app/help/docs/comparing-folders,
https://kaleidoscope.app/help/docs/merging-folder-contents, and
https://kaleidoscope.app/help/docs/folder-compare-settings

- [ ] Hierarchical exact comparison with progress, expandable differences, and live refresh.
- [ ] Hidden-file and named ignore patterns; filters by state and name.
- [ ] Double-click text/image pair, Quick Look, and metadata details.
- [ ] A→B/B→A copy preserves destination-only items and obeys visible selection.
- [ ] Clone preview enumerates replacements and deletions; recover after failure.
- [ ] Symlink, package, permission, and traversal safety cases pass.

## Git

Sources: https://kaleidoscope.app/help/docs/repository-view,
https://kaleidoscope.app/help/docs/changeset-window,
https://kaleidoscope.app/help/docs/file-history, and
https://blog.kaleidoscope.app/2026/07/28/kaleidoscope-7-live-working-copy-changes/

- [ ] Recent repositories and worktrees; current ref and working-copy status.
- [ ] Working-copy staged, unstaged, partial, untracked, and deleted changes.
- [ ] Live changeset updates, pause/resume, refresh, and notifications.
- [ ] Changeset list/outline, kind/type/name filters, and cross-file navigation.
- [ ] Compare commits, tags, branches, worktrees, and working copy.
- [ ] Commit list/graph, commit details, changeset history, and file history.
- [ ] Conflict context, base-to-side comparison, and correct mergetool exit behavior.

## Integrations and delivery

Sources: https://kaleidoscope.app/help/docs/command-line-tool,
https://kaleidoscope.app/help/docs/kaleidoscope-url-scheme,
https://kaleidoscope.app/help/docs/kaleidoscope-prism, and installed Integration guide.

- [ ] `macdiff` diff/merge/changeset/working-copy, stdin, snapshots, wait and exit codes.
- [ ] Same-user IPC and original `macdiffstudio://` scheme.
- [ ] Reversible opt-in Git difftool/mergetool setup.
- [ ] Finder Services, Share Extension, Shortcuts, and menu bar drop helper.
- [ ] Local recipes for Xcode, VS Code, JetBrains, Android Studio, BBEdit, TextMate.
- [ ] Local recipes for Raycast, Alfred, Python, Safari, Jujutsu, Subversion,
      Mercurial, Bazaar, and other documented integration entries.
- [ ] Two-version no-fee in-app update proof; signed archive/feed and tamper rejection.
- [ ] Release Homebrew cask; verify clean install, upgrade, uninstall, and CLI linking.
- [ ] PR and scheduled macOS 27 CI, local UI/performance gates, release/rollback procedure.

