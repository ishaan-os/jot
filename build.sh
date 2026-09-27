#!/bin/zsh
# Builds Jot.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/Jot.app
rm -rf build && mkdir -p $APP/Contents/MacOS
# Hides a stale duplicate SwiftBridging modulemap in this machine's Command Line Tools
# (/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap) that breaks swiftc.
mkdir -p .toolchain-fix && : > .toolchain-fix/empty.modulemap
cat > .toolchain-fix/overlay.yaml <<YAML
{ "version": 0, "roots": [ { "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap", "type": "file", "external-contents": "$PWD/.toolchain-fix/empty.modulemap" } ] }
YAML
swiftc -O -swift-version 5 -target arm64-apple-macos14 -vfsoverlay .toolchain-fix/overlay.yaml \
  -module-cache-path .toolchain-fix/module-cache main.swift -o $APP/Contents/MacOS/Jot
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ishaan.jot</string>
  <key>CFBundleName</key><string>Jot</string>
  <key>CFBundleExecutable</key><string>Jot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP
pkill -x Jot || true
rm -rf ~/Applications/Jot.app && cp -R $APP ~/Applications/
echo "Installed ~/Applications/Jot.app — run: open ~/Applications/Jot.app"
