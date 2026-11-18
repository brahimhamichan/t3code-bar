#!/bin/sh
# Builds "T3code Bar.app" next to this script.
# Use ./build.sh release to build a notarized DMG in dist/.
set -eu
cd "$(dirname "$0")"

APP="T3code Bar.app"
if [ "${1:-}" = release ]; then
    APP="dist/$APP"
fi
CONTENTS="$APP/Contents"
MIN_MACOS=$(plutil -extract LSMinimumSystemVersion raw Info.plist)
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp Info.plist "$CONTENTS/Info.plist"
cp icons/*.svg icons/AppIcon.icns "$CONTENTS/Resources/"

if [ "${1:-}" = release ]; then
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    for arch in arm64 x86_64; do
        swiftc -O -parse-as-library -target "$arch-apple-macos$MIN_MACOS" App.swift -o "$WORK/$arch"
    done
    lipo -create "$WORK/arm64" "$WORK/x86_64" -output "$CONTENTS/MacOS/T3codeBar"
    SIGN_ID=${DEVELOPER_ID_APPLICATION:-Developer ID Application: Scaling Adventures LLC (3G5832B4DA)}
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    ./script/make-dmg.sh "$APP" dist/T3codeBar.dmg
else
    swiftc -O -parse-as-library -target "$(uname -m)-apple-macos$MIN_MACOS" App.swift -o "$CONTENTS/MacOS/T3codeBar"
fi
