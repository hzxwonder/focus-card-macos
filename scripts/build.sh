#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="build/FocusCard.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
cp resources/Info.plist "$bundle/Info.plist"
xcrun clang -fobjc-arc -fno-modules src/FocusCard.m -o "$bundle/MacOS/FocusCard" \
    -framework Cocoa -framework QuartzCore -framework UserNotifications \
    -mmacosx-version-min=13.0
"$bundle/MacOS/FocusCard" --self-test
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
"$bundle/MacOS/FocusCard" --export-icons "$task_dir/FocusCard.iconset"
iconutil -c icns "$task_dir/FocusCard.iconset" -o "$bundle/Resources/FocusCard.icns"
codesign --force --sign - build/FocusCard.app
codesign --verify --strict build/FocusCard.app
echo 'Built / 已生成: build/FocusCard.app'
