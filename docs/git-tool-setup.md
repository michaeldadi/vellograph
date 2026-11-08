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
worktree use the repository's common Git configuration. This workflow has
passed disposable-repository difftool and mergetool tests. It has not yet been
qualified against the installed app or a final release package.
