#!/bin/zsh
set -eu

if [[ $# -ne 1 ]]; then
  print -u2 'Usage: verify-app-bundle.sh /path/to/Vellograph.app'
  exit 2
fi

app=$1
info="$app/Contents/Info.plist"
[[ -f "$info" ]] || { print -u2 "Missing bundle Info.plist: $info"; exit 1; }

executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
[[ "$executable" == Vellograph ]] || { print -u2 "Unexpected GUI executable: $executable"; exit 1; }
[[ "$bundle_id" == io.github.michaeldadi.vellograph ]] || {
  print -u2 "Unexpected bundle identifier: $bundle_id"
  exit 1
}

gui="$app/Contents/MacOS/$executable"
cli="$app/Contents/Helpers/vellograph"
[[ -x "$gui" && -x "$cli" ]] || {
  print -u2 'The GUI or bundled CLI executable is missing.'
  exit 1
}
if /usr/bin/cmp -s "$gui" "$cli"; then
  print -u2 'The GUI executable was replaced by the bundled CLI.'
  exit 1
fi

for binary in "$gui" "$cli"; do
  if ! /usr/bin/lipo -archs "$binary" | /usr/bin/grep -qw arm64; then
    print -u2 "Missing arm64 architecture: $binary"
    exit 1
  fi
done

extension="$app/Contents/PlugIns/VellographCompareAction.appex"
extension_info="$extension/Contents/Info.plist"
extension_binary="$extension/Contents/MacOS/VellographCompareAction"
[[ -f "$extension_info" && -x "$extension_binary" ]] || {
  print -u2 'The comparison Action extension is missing from the app bundle.'
  exit 1
}
extension_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension_info")
extension_point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$extension_info")
extension_role=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:NSExtensionServiceRoleType' "$extension_info")
[[ "$extension_id" == io.github.michaeldadi.vellograph.compare-action &&
   "$extension_point" == com.apple.ui-services &&
   "$extension_role" == NSExtensionServiceRoleTypeViewer ]] || {
  print -u2 'The comparison Action extension has unexpected metadata.'
  exit 1
}
if ! /usr/bin/lipo -archs "$extension_binary" | /usr/bin/grep -qw arm64; then
  print -u2 'The comparison Action extension is missing arm64 architecture.'
  exit 1
fi

share="$app/Contents/PlugIns/VellographCompareShare.appex"
share_info="$share/Contents/Info.plist"
share_binary="$share/Contents/MacOS/VellographCompareShare"
[[ -f "$share_info" && -x "$share_binary" ]] || {
  print -u2 'The comparison Share extension is missing from the app bundle.'
  exit 1
}
share_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$share_info")
share_point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$share_info")
[[ "$share_id" == io.github.michaeldadi.vellograph.compare-share &&
   "$share_point" == com.apple.share-services ]] || {
  print -u2 'The comparison Share extension has unexpected metadata.'
  exit 1
}
if ! /usr/bin/lipo -archs "$share_binary" | /usr/bin/grep -qw arm64; then
  print -u2 'The comparison Share extension is missing arm64 architecture.'
  exit 1
fi

help=$($cli --help)
[[ "$help" == *'vellograph diff'* && "$help" == *'vellograph git-tool'* ]] || {
  print -u2 'The bundled CLI did not return its command list.'
  exit 1
}

print 'Verified Vellograph GUI, bundled CLI, Action extension, and Share extension.'
