#!/bin/zsh
set -eu

if [[ $# -ne 1 ]]; then
  print -u2 'Usage: verify-cli-failures.sh /path/to/Vellograph.app'
  exit 2
fi

cli="$1/Contents/Helpers/vellograph"
[[ -x "$cli" ]] || { print -u2 "Missing bundled command: $cli"; exit 1; }
fixture=$(mktemp -d /tmp/vellograph-cli-failures.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
print 'base' > "$fixture/base.txt"
print 'local' > "$fixture/local.txt"
print 'remote' > "$fixture/remote.txt"

expect_invalid() {
  local exit_code=0
  "$cli" "$@" > "$fixture/stdout" 2> "$fixture/stderr" || exit_code=$?
  if [[ $exit_code -ne 2 ]]; then
    print -u2 "Expected status 2, got $exit_code: $*"
    exit 1
  fi
  [[ -s "$fixture/stderr" ]] || { print -u2 "Missing error message: $*"; exit 1; }
}

expect_invalid diff "$fixture/missing.txt"
expect_invalid diff --label A --label B "$fixture/base.txt"
expect_invalid diff - -
expect_invalid diff --unknown "$fixture/base.txt"
expect_invalid merge --base "$fixture/missing.txt" --output "$fixture/out.txt" -- \
  "$fixture/local.txt" "$fixture/remote.txt"
expect_invalid merge --base "$fixture/base.txt" --output "$fixture/out.txt" \
  --output "$fixture/other.txt" -- "$fixture/local.txt" "$fixture/remote.txt"
expect_invalid changeset --repo "$fixture/missing-repo" --from HEAD --to HEAD~1
[[ ! -e "$fixture/out.txt" && ! -e "$fixture/other.txt" ]] || {
  print -u2 'Invalid merge created an output file.'
  exit 1
}

print 'Verified invalid CLI requests return status 2 without output.'
