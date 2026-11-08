# Local integration recipes

These recipes call Vellograph's own executable. They are opt-in and keep compared
content on this Mac. The current development app installs it at
`~/Applications/Vellograph.app/Contents/Helpers/vellograph`; use that full path
until a Homebrew release provides a stable shell command. Run `--help` to check
the executable before configuring a host. Git difftool/mergetool and Safari's
local URL have passed host-level checks; the other host recipes below still
need their own acceptance checks.

## Git, Xcode, and editor terminals

Preview Git's exact changes and choose repository-local or global scope with
the reversible commands in [git-tool-setup.md](git-tool-setup.md). Once
installed, `git difftool` and `git mergetool` can be run while working in Xcode,
VS Code, JetBrains IDEs, BBEdit, TextMate, or Android Studio. Use the IDE's
terminal where it has one, or the macOS Terminal otherwise. This route does
not replace those apps' built-in visual diff buttons.

For an ordinary pair of local files, run from the host's terminal:

```sh
"$HOME/Applications/Vellograph.app/Contents/Helpers/vellograph" diff -- \
  "/absolute/path/to/before" "/absolute/path/to/after"
```

Add `--wait` before `--` if the host must wait for the Vellograph tab to close.
Do not use `--wait` for background or noninteractive tasks. Xcode's documented
`opendiff` command launches FileMerge; Vellograph does not replace it.
[Apple's Xcode command reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference),
[VS Code CLI reference](https://code.visualstudio.com/docs/configure/command-line).

## JetBrains External Diff Tools

In a JetBrains IDE, open Settings → Tools → Diff & Merge → External Diff Tools,
enable external tools, and add a **Diff tool** with:

| Field | Value |
| --- | --- |
| Program path | `/Users/michaeldadi/Applications/Vellograph.app/Contents/Helpers/vellograph` |
| Argument pattern | `diff --wait -- %1 %2` |

Use **Test Diff** with disposable files before relying on the configuration.
The host's `%1` and `%2` meanings vary with comparison context, so inspect A/B
orientation in the opened Vellograph tab. Three-side external merge configuration
needs separate verification. [JetBrains external-tool instructions](https://www.jetbrains.com/help/idea/comparing-files-and-folders.html#external_diff_tool).

## Raycast

Create a local Raycast Script Command with two required path arguments. Save
this as an executable `.sh` file in a Script Directory, then run it from
Raycast's search. The script does not acquire Finder selection by itself.

```sh
#!/bin/zsh
# @raycast.schemaVersion 1
# @raycast.title Compare in Vellograph
# @raycast.mode silent
# @raycast.argument1 { "type": "text", "placeholder": "First local path" }
# @raycast.argument2 { "type": "text", "placeholder": "Second local path" }

exec "$HOME/Applications/Vellograph.app/Contents/Helpers/vellograph" diff -- "$1" "$2"
```

Use existing, absolute paths; the CLI rejects missing input. [Raycast Script
Commands](https://manual.raycast.com/script-commands), [argument metadata](https://github.com/raycast/script-commands/blob/master/documentation/ARGUMENTS.md).

## Alfred

An Alfred Workflow can collect file paths through File Filter inputs or a file
action, then pass two separate paths to a Run Script action. Call the same CLI
command shown above with quoted arguments. Check how the workflow passes
multiple files before using it as a merge tool; no Alfred workflow is installed
by this repository. [Alfred workflow inputs](https://www.alfredapp.com/help/workflows/inputs/),
[file actions](https://www.alfredapp.com/help/workflows/actions/open-file/).

## Python

Use argument arrays and let the CLI report its documented exit status. This
opens a comparison and returns after the app accepts it; add `--wait` if the
calling script needs the tab to close.

```python
from pathlib import Path
import subprocess

cli = Path.home() / "Applications/Vellograph.app/Contents/Helpers/vellograph"
subprocess.run([str(cli), "diff", "--", str(Path("before.txt").resolve()),
                str(Path("after.txt").resolve())], check=True)
```

## Safari and local URLs

For a browser page that deliberately links to local sources, the original
`vellograph://` scheme can open compare, history, or changeset requests. Use
the exact URL grammar and encoding rules in [url-scheme.md](url-scheme.md).
Safari opened a local history request on this Mac; a distributable Safari
extension has not been built or qualified.

## Jujutsu

Jujutsu supports a named external tool for file-by-file diff and a three-way
merge tool with `$left`, `$base`, `$right`, and `$output` substitutions. The
following is a configuration template for `jj config edit --user`; run a
disposable conflict through `jj resolve` before relying on it:

```toml
[merge-tools.vellograph]
program = "/Users/michaeldadi/Applications/Vellograph.app/Contents/Helpers/vellograph"
diff-invocation-mode = "file-by-file"
diff-args = ["diff", "--wait", "--", "$left", "$right"]
merge-args = ["merge", "--base", "$base", "--output", "$output", "--", "$left", "$right"]

[ui]
merge-editor = "vellograph"
```

Use `jj diff --tool vellograph` for an explicit diff. Jujutsu's directory-based
editing mode expects writes to its `$right` directory, so this recipe does not
configure `ui.diff-editor`. [Jujutsu tool configuration](https://docs.jj-vcs.dev/latest/config/).

## Subversion, Mercurial, and Bazaar

These tools have different external diff and merge calling conventions. For
now, export or identify two concrete local versions and run `vellograph diff`
on their paths. Do not point `svn --diff-cmd` or a merge hook directly at the
CLI without a tested adapter that translates its arguments and exit semantics.
[Subversion external tools](https://svnbook.red-bean.com/en/1.8/svn.advanced.externaldifftools.html),
[Mercurial merge tools](https://www.mercurial-scm.org/help/topics/merge-tools).
