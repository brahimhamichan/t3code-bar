#!/bin/sh
# Builds "T3code Bar.app" next to this script.
set -e; cd "$(dirname "$0")"
A="T3code Bar.app/Contents"; rm -rf "T3code Bar.app"; mkdir -p "$A/MacOS" "$A/Resources"
swiftc -O -parse-as-library App.swift -o "$A/MacOS/T3codeBar"
cp icons/*.svg "$A/Resources/"
cat > "$A/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.brahimhamichan.t3code-bar</string><key>CFBundleName</key><string>T3code Bar</string>
<key>CFBundleExecutable</key><string>T3codeBar</string><key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
P
