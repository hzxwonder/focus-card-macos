#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh --screenshots

validation="build/test-app/FocusCard.app"
mkdir -p build/test-app
ditto build/FocusCard.app "$validation"
cmp build/FocusCard.app/Contents/MacOS/FocusCard "$validation/Contents/MacOS/FocusCard"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.focuscard.validation' "$validation/Contents/Info.plist"
codesign --force --sign - "$validation"

status=0
for language in zh en; do
    results="build/test-results/ui-$language"
    mkdir -p "$results"
    if ! FOCUSCARD_LANG=$language "$validation/Contents/MacOS/FocusCard" --ui-test "$results" "$language" > "$results/run.log" 2>&1; then
        status=1
    fi
    tail -n 2 "$results/run.log"
done
exit "$status"
