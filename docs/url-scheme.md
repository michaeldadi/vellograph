# Vellograph URL scheme

The app registers `vellograph://` for local comparison requests. Query values
are percent encoded absolute filesystem paths or Git revision names. The link
parser rejects extra fields, remote source URLs, credentials, and malformed
requests. It never runs query values as shell commands.

| Link | Result |
| --- | --- |
| `vellograph://compare?file=%2Fpath%2Fa.txt&file=%2Fpath%2Fb.txt` | Compare one or two existing local sources. `diff` is an alias for `compare`. |
| `vellograph://history?repo=%2Fpath%2Frepository` | Open a local Git repository in History. |
| `vellograph://changeset?repo=%2Fpath%2Frepository&from=HEAD%7E1&to=HEAD` | Compare two Git revisions in a local repository. |

The parser and repository validation have package tests. On macOS 27.2,
Safari delivered a `history` link through Launch Services to a locally signed
development build in `~/Applications`; Vellograph opened the repository with
History selected. Compare and changeset links still need host-app checks.
