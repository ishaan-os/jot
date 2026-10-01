#!/bin/zsh
# Builds Jot.app and installs it to ~/Applications (--no-install: just build into build/).
#   UNIVERSAL=1      build for Apple Silicon + Intel (releases)
#   SIGN_IDENTITY=…  sign with a Developer ID (hardened runtime) instead of ad-hoc
set -e
cd "$(dirname "$0")"
APP=build/Jot.app
BUNDLE_ID=io.github.ishaan-os.jot
VERSION=$(cat VERSION)
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
ARCHS=($(uname -m))
[[ -n "$UNIVERSAL" ]] && ARCHS=(arm64 x86_64)
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14" $FLAGS main.swift -o build/Jot-$arch
done
lipo -create build/Jot-* -output $APP/Contents/MacOS/Jot && rm build/Jot-*
cp assets/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Jot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Jot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" $APP
else
  # Source builds: pin the designated requirement to the bundle id (ad-hoc signatures otherwise
  # default to the per-build cdhash, which makes macOS forget the Accessibility grant on every rebuild).
  codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" $APP
fi
[[ "$1" == "--no-install" ]] && { echo "Built $APP ($VERSION)"; exit 0; }
pkill -x Jot || true
rm -rf ~/Applications/Jot.app && cp -R $APP ~/Applications/
echo "Installed ~/Applications/Jot.app — run: open ~/Applications/Jot.app"
