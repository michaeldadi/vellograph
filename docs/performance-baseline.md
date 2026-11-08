# Local performance baseline — 2026-11-08

This is a repeatable **core** benchmark on the author's Mac16,8 running macOS
27.2 with Xcode 27.2, followed by single-run app signpost measurements. Neither
measurement establishes the time to draw the first visible viewport. That
release gate remains open.

Build the release-mode probe and run the two workloads separately:

```sh
swift build -c release --product vellograph-bench
/usr/bin/time -l .build/release/vellograph-bench
/usr/bin/time -l .build/release/vellograph-bench --folder100k
/usr/bin/time -l .build/release/vellograph-bench --git-busy
mkdir -p .build/ui-fixtures
sips -z 4096 4096 Artwork/VellographIcon-master.png \
  --out .build/ui-fixtures/bench-icon-a.png
sips -r 90 .build/ui-fixtures/bench-icon-a.png \
  --out .build/ui-fixtures/bench-icon-b.png
/usr/bin/time -l .build/release/vellograph-bench --image \
  .build/ui-fixtures/bench-icon-a.png .build/ui-fixtures/bench-icon-b.png
sips -z 5000 5000 Artwork/VellographIcon-master.png \
  --out .build/ui-fixtures/bench-icon-5000-a.png
sips -r 90 .build/ui-fixtures/bench-icon-5000-a.png \
  --out .build/ui-fixtures/bench-icon-5000-b.png
/usr/bin/time -l .build/release/vellograph-bench --image \
  .build/ui-fixtures/bench-icon-5000-a.png .build/ui-fixtures/bench-icon-5000-b.png
sips -s format jpeg Tests/fixtures/huge-solid.png \
  --out .build/ui-fixtures/huge-solid.jpg
/usr/bin/time -l .build/release/vellograph-bench --image \
  Tests/fixtures/huge-solid.png .build/ui-fixtures/huge-solid.jpg
```

| Workload | Observed core time | Peak resident memory of process |
| --- | ---: | ---: |
| 16,384-line, 0.91 MiB text pair; one changed line | Parse 0.033 s; diff 0.033 s; display rows <0.001 s | 170 MB for the process running both text cases |
| 163,840-line, 9.27 MiB text pair; one changed line | Parse 0.241 s; diff 0.345 s; display rows 0.002 s | Same process as above |
| One 100,000-entry folder against an empty folder | Compare 0.513–0.632 s on two later runs | 136–143 MB including fixture creation and cleanup |
| Git worktree with 5,000 tracked files and 1,125 changed paths | Repository open 0.346 s; repeated status 0.112 / 0.108 / 0.117 s | 14.5 MB including fixture creation and cleanup |
| 4096 × 4096 PNG pair; 12,621,444 changed pixels | Decode and pixel difference 0.421 s | 287 MB for the process |
| 5000 × 5000 PNG pair; 18,805,938 changed pixels | Decode and pixel difference 0.861 s | 420 MB for the process |
| 8192 × 8192 PNG/JPEG pair, reduced to a 4096² sampled preview; 16,777,216 changed samples | Decode and preview difference 1.602 s | 165 MB for the process |

The folder fixture has 100 directories and 99,900 empty files. Its total
roughly 19–20-second process lifetime on the two later runs includes creating
and removing the fixture; only the 0.513–0.632-second comparison interval is
timed as core work. An earlier run measured 1.071 seconds and 81 MB peak.
These are isolated runs, not controlled distributions. Re-run on the target
build before using them as regression gates. App-level first-viewport,
scrolling, large-image, and busy Git worktree measurements remain open.

The Git fixture includes staged, unstaged, partially staged, deleted, and
untracked paths. Its 3.42-second process lifetime includes creating a fresh
repository, committing the baseline, changing files, and removing the fixture;
the table times only the Git repository and status calls. The weekly CI probe
records these timings but does not yet enforce a runner-specific threshold.

The image probe generates disposable files from the app's own icon and holds
them under `.build/ui-fixtures`. It times ImageIO decode plus a complete
difference mask, excluding the process startup measured by `/usr/bin/time`.
The 287 MB figure is the process peak, including decoded inputs and mask. This does not
measure SwiftUI drawing, scrolling, or the full app's memory use.

Full-resolution pixel inspection and alignment still reject an 8192 × 8192
source before decoding. The Difference view now uses ImageIO subsampling for
large sources and explicitly labels its count as sampled pixels. The 8192²
PNG/JPEG preview above finished in 2.20 seconds including process startup;
the earlier ImageIO thumbnail version took 1.94 seconds but peaked at 715 MB.
The 5000 × 5000 probe remains an exact full-resolution comparison. All memory
figures are single release-mode process peaks, not app-level measurements.

## Installed-app signposts

The signed Release app installed at `~/Applications/Vellograph.app` was traced
with Xcode 27.2's **Logging** template on the same Mac on November 8, 2026.
`OSSignposter` intervals use the `io.github.michaeldadi.vellograph` subsystem.
The text pair was generated as 163,840 lines and 8.9 MiB per file, with one
changed line. Both image pairs were PNGs derived from the app icon.

| Installed-app operation | Single observed signpost interval |
| --- | ---: |
| `OpenComparison` for the text pair sent through the bundled CLI | 692.69 ms |
| `PrepareImages` after selecting the image tab | 13.73 ms |
| `CalculateDifference` after selecting Difference mode | 439.71 ms |
| `OpenComparison` for a changed 8192 × 8192 image pair | 225.17 ms |
| `PrepareImages` for that large image pair | 21.11 ms |
| `CalculateDifference` for its 4096² sampled preview | 1.14 s |

The app accessibility tree showed the text comparison with one change and the
image difference with 12,621,444 changed pixels out of 16,777,216. The first
trace also captured an image `OpenComparison` interval of 12.96 ms and
`PrepareImages` of 23.86 ms. Its text request happened before the recorder was
ready, so only the second text trace is used above. These intervals cover the
named operations in the code, not CLI startup, socket handoff, first rendered
frame, scrolling, or peak app memory. `PrepareImages` may defer image decoding
until drawing; the difference interval includes the explicit pixel calculation.
The large-image view visibly labeled its result “Preview: 12,614,169 of
16,777,216 sampled pixels differ” and rendered the difference mask. The
large-image numbers also come from one trace, not a repeatable distribution.

To reproduce: attach `xcrun xctrace record --template Logging --attach <app-pid>
--time-limit 22s --output <path>.trace`, wait for recording to start, invoke the
bundled `vellograph diff -- <absolute-left> <absolute-right>` command or select
Difference in the app, then export the `OSSignpostIntervals` table with
`xcrun xctrace export --input <path>.trace --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]'`.
The trace bundles were kept outside the repository under `/tmp` because they
include process environment and local paths.
