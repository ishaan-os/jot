#!/bin/zsh
# Builds a signed, notarized dist/Jot-<version>.dmg. Run by .github/workflows/release.yml.
# Needs: SIGN_IDENTITY (in an unlocked keychain), NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID.
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait)

UNIVERSAL=1 ./build.sh --no-install

# Notarize + staple the app itself so it opens offline too, then ship it inside a signed,
# notarized DMG with an Applications shortcut.
ditto -c -k --keepParent build/Jot.app build/Jot.zip
xcrun notarytool submit build/Jot.zip $NOTARY
xcrun stapler staple build/Jot.app

rm -rf dist build/dmg && mkdir -p dist build/dmg
cp -R build/Jot.app build/dmg/ && ln -s /Applications build/dmg/Applications
DMG=dist/Jot-$VERSION.dmg
hdiutil create -volname "Jot $VERSION" -srcfolder build/dmg -ov -format UDZO $DMG
codesign --force --timestamp --sign "$SIGN_IDENTITY" $DMG
xcrun notarytool submit $DMG $NOTARY
xcrun stapler staple $DMG
shasum -a 256 $DMG
