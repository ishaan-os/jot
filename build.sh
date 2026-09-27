#!/bin/zsh
# Builds Jot.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/Jot.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
FLAGS=()
# Some Command Line Tools installs ship a stale duplicate SwiftBridging modulemap that breaks
# swiftc ("redefinition of module 'SwiftBridging'"); hide it with a VFS overlay if present.
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $STALE && -f ${STALE:h}/bridging.modulemap ]]; then
  mkdir -p .toolchain-fix && : > .toolchain-fix/empty.modulemap
  echo "{ \"version\": 0, \"roots\": [ { \"name\": \"$STALE\", \"type\": \"file\", \"external-contents\": \"$PWD/.toolchain-fix/empty.modulemap\" } ] }" > .toolchain-fix/overlay.yaml
  FLAGS=(-vfsoverlay .toolchain-fix/overlay.yaml -module-cache-path $PWD/.toolchain-fix/module-cache)
fi
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" $FLAGS main.swift -o $APP/Contents/MacOS/Jot
cp assets/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.ishaan.jot</string>
  <key>CFBundleName</key><string>Jot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
