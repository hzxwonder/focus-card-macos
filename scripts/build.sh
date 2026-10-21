#!/bin/bash
# Builds build/FocusCard.app, runs the self-test in both languages and signs the bundle ad hoc.
# Usage: bash scripts/build.sh [--screenshots]
set -euo pipefail
cd "$(dirname "$0")/.."
bundle="build/FocusCard.app/Contents"
binary="$bundle/MacOS/FocusCard"
mkdir -p "$bundle/MacOS" "$bundle/Resources" build/test-results
cp resources/Info.plist "$bundle/Info.plist"
cp LICENSE "$bundle/Resources/LICENSE"

xcrun clang -fobjc-arc -fno-modules -Wall -Wextra -Wno-unused-parameter -O2 src/FocusCard.m -o "$binary" \
    -framework Cocoa -framework QuartzCore -framework UserNotifications -framework ServiceManagement \
    -mmacosx-version-min=13.0

if [[ "${1:-}" == "--screenshots" ]]; then
    for lang in zh en; do FOCUSCARD_LANG=$lang "$binary" --render-screenshots build/screenshots; done
fi

for lang in zh en; do
    echo "== Self-test ($lang)"
    FOCUSCARD_LANG=$lang "$binary" --self-test "build/test-results/self-test-$lang.json"
done

task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
"$binary" --export-icons "$task_dir/FocusCard.iconset"
iconutil -c icns "$task_dir/FocusCard.iconset" -o "$bundle/Resources/FocusCard.icns"
codesign --force --sign - build/FocusCard.app
codesign --verify --strict build/FocusCard.app
echo 'Built / 已生成: build/FocusCard.app'
