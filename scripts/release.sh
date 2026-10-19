#!/bin/bash
# Builds Swivel for release: signs the app, its Quick Action and the `swivel`
# command with Developer ID, notarizes and staples the app, then packages,
# signs, notarizes and staples Swivel.dmg. Prints the checksum and updates
# the Homebrew cask in packaging/homebrew/swivel.rb.
#
# Needs (see docs/dev/releasing.md):
#   SWIVEL_TEAM_ID         the Apple Developer team ID (10 characters)
#   a "Developer ID Application" certificate for that team in the keychain
#   a notarytool keychain profile, "swivel-notary" unless SWIVEL_NOTARY_PROFILE says otherwise
set -euo pipefail

cd "$(dirname "$0")/.."
die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

: "${SWIVEL_TEAM_ID:?Set SWIVEL_TEAM_ID to your Apple Developer team ID}"
PROFILE="${SWIVEL_NOTARY_PROFILE:-swivel-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Outside ~/Documents, which iCloud syncs (its file attributes break signing).
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/Converter}"
DERIVED="$BUILD_ROOT/DerivedData-release"
CLI_BUILD="$BUILD_ROOT/ConverterCore-release"
OUT="$BUILD_ROOT/release"

IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .*($SWIVEL_TEAM_ID)\)\"/\1/p" | head -1)
[ -n "$IDENTITY" ] || die "no \"Developer ID Application\" certificate for team $SWIVEL_TEAM_ID in the keychain"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "no notarytool profile \"$PROFILE\"; run: xcrun notarytool store-credentials $PROFILE"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' Converter/project.yml)
[ -n "$VERSION" ] || die "couldn't read MARKETING_VERSION from Converter/project.yml"
grep -q "static let version = \"$VERSION\"" Packages/ConverterCore/Sources/swivel/CLI.swift \
    || die "the swivel command's version (CLI.swift) doesn't match $VERSION"
[ -z "$(git status --porcelain)" ] || echo "release: warning: the working tree has uncommitted changes" >&2

step "Building Swivel $VERSION"
rm -rf "$DERIVED" "$OUT"
mkdir -p "$OUT"
(cd Converter && xcodegen generate --quiet)
set -o pipefail
xcodebuild -project Converter/Converter.xcodeproj -scheme Converter -configuration Release \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
swift build -c release --arch arm64 --package-path Packages/ConverterCore --scratch-path "$CLI_BUILD" 2>&1 | tail -1
CLI="$(swift build -c release --arch arm64 --package-path Packages/ConverterCore --scratch-path "$CLI_BUILD" --show-bin-path)/swivel"

APP="$OUT/Swivel.app"
ditto "$DERIVED/Build/Products/Release/Swivel.app" "$APP"
mkdir -p "$APP/Contents/Helpers"
cp "$CLI" "$APP/Contents/Helpers/swivel"

step "Signing with $IDENTITY"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
# Inside out: nested code first, the app last.
sign --identifier io.github.jonathanlotan.Swivel.cli "$APP/Contents/Helpers/swivel"
sign --entitlements Converter/QuickAction/QuickAction.entitlements "$APP/Contents/PlugIns/ConverterQuickAction.appex"
sign "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

step "Notarizing the app (this takes a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/Swivel-notarize.zip"
xcrun notarytool submit "$OUT/Swivel-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/Swivel-notarize.zip"

step "Packaging Swivel.dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Swivel.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Swivel" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/Swivel.dmg"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$OUT/Swivel.dmg"
xcrun notarytool submit "$OUT/Swivel.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Swivel.dmg"

step "Checking what Gatekeeper will say"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/Swivel.dmg"
xcrun stapler validate "$OUT/Swivel.dmg"
"$APP/Contents/Helpers/swivel" --version

SHA=$(shasum -a 256 "$OUT/Swivel.dmg" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" packaging/homebrew/swivel.rb
echo "$SHA  Swivel.dmg" > "$OUT/Swivel.dmg.sha256"

step "Done"
echo "  $OUT/Swivel.dmg ($(du -h "$OUT/Swivel.dmg" | cut -f1))"
echo "  sha256 $SHA"
echo "  packaging/homebrew/swivel.rb now points at v$VERSION"
echo
echo "Next: gh release create v$VERSION \"$OUT/Swivel.dmg\" \"$OUT/Swivel.dmg.sha256\" --title \"Swivel $VERSION\" --notes-file <notes>"
echo "      then copy packaging/homebrew/swivel.rb to Casks/ in jonathanlotan/homebrew-tap and push."
