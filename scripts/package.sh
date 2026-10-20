#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! git diff --quiet HEAD --; then
    echo 'Commit the source changes before packaging / 请先提交源码更改。' >&2
    exit 1
fi
bash scripts/build.sh
app="build/FocusCard.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
architecture=$(lipo -archs "$app/Contents/MacOS/FocusCard")
case "$architecture" in arm64|x86_64) ;; *) echo 'Unsupported archive architecture' >&2; exit 1;; esac
name="FocusCard-$version-macos-$architecture"
output="build/release"
mkdir -p "$output"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$name.zip"
unzip -tq "$output/$name.zip"

task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
ditto -x -k "$output/$name.zip" "$task_dir"
codesign --verify --strict "$task_dir/FocusCard.app"
cmp "$app/Contents/MacOS/FocusCard" "$task_dir/FocusCard.app/Contents/MacOS/FocusCard"
for language in zh en; do
    FOCUSCARD_LANG=$language "$task_dir/FocusCard.app/Contents/MacOS/FocusCard" \
        --self-test "build/test-results/packaged-$language.json"
done
{
    printf 'Version: %s\nArchitecture: %s\n' "$version" "$architecture"
    printf 'Commit: %s\n' "$(git rev-parse HEAD)"
    printf 'macOS: %s\n' "$(sw_vers -productVersion)"
    printf 'Signature: ad hoc\nNotarization: none\n'
} > "$output/BUILD-INFO.txt"
(cd "$output" && shasum -a 256 "$name.zip" BUILD-INFO.txt > SHA256SUMS.txt)
echo "Package / 软件包: $output/$name.zip"
