# Git difftool and mergetool setup

Vellograph's CLI can be used as Git's difftool and mergetool. Use a stable,
installed `vellograph` executable path. Development binaries under `.build/`
move when the package is rebuilt and are unsuitable for persistent Git config.

Preview the exact new settings before changing either scope:

```sh
vellograph git-tool preview --repo /path/to/repository --cli /path/to/vellograph
vellograph git-tool preview --global --cli /path/to/vellograph
```

Install only for the chosen scope:

```sh
vellograph git-tool install --repo /path/to/repository --cli /path/to/vellograph --yes
vellograph git-tool install --global --cli /path/to/vellograph --yes
```

The installer writes `diff.tool`, `difftool.vellograph.cmd`, `merge.tool`,
`mergetool.vellograph.cmd`, and `mergetool.vellograph.trustExitCode`. It stores
previous values in a private backup under
`~/Library/Application Support/Vellograph/GitToolBackups/`. Other Git settings
are left alone. A repeated install with the same settings is harmless.

Try `git difftool --no-prompt` for a changed file. The CLI waits for the
comparison tab to close. `git mergetool` waits for a saved resolution and
returns a failure status when the merge is closed without saving.

Restore the previous values with the same scope:

```sh
vellograph git-tool uninstall --repo /path/to/repository
vellograph git-tool uninstall --global
```

Uninstall refuses to overwrite a Git tool value changed since installation;
the backup remains available for manual review. Local settings for a linked
worktree use the repository's common Git configuration. A disposable conflict
invoked through Git's actual `mergetool` host on this Mac returned failure
when the Vellograph tab was closed unresolved; the index kept its three
unmerged stages. Repeating it, saving a Remote resolution, and exiting
returned success, wrote the exact selected bytes, and cleared those stages.
Repository-local uninstall then removed the tool settings. The final release
package still needs this host check.

A disposable Git repository also invoked the installed Release app through
`git difftool --no-prompt --tool=vellograph`. Its native comparison showed the
committed `before` content on A and the working file's `after` content on B.
Closing the tab returned Git status 0; the working file remained modified and
repository-local uninstall removed the tool setting.
