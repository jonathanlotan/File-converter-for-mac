#!/bin/bash
# Publishes what `make release` built, after it has been checked:
#   1. dates the version's changelog entry and commits it with the updated cask, then pushes main
#   2. creates (or fills in and publishes) the GitHub release vVERSION with Swivel.dmg
#   3. copies the cask to jonathanlotan/homebrew-tap, creating that repository the first time
# Refuses to run unless Swivel.dmg is notarized and matches the cask.
set -euo pipefail

cd "$(dirname "$0")/.."
die() { echo "publish: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

REPO=jonathanlotan/Swivel
TAP=jonathanlotan/homebrew-tap
BUILD_ROOT="${BUILD_ROOT:-$HOME/Library/Caches/Converter}"
OUT="$BUILD_ROOT/release"
DMG="$OUT/Swivel.dmg"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' Converter/project.yml)
TAG="v$VERSION"
[ -f "$DMG" ] || die "no $DMG; run make release first"
spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null \
    || die "Swivel.dmg isn't signed and notarized; run make release (needs the Developer ID)"
xcrun stapler validate -q "$DMG" || die "Swivel.dmg has no notarization ticket stapled"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
grep -q "sha256 \"$SHA\"" packaging/homebrew/swivel.rb || die "packaging/homebrew/swivel.rb doesn't match Swivel.dmg; rerun make release"
grep -q "^  version \"$VERSION\"" packaging/homebrew/swivel.rb || die "the cask isn't at version $VERSION"
[ "$(git branch --show-current)" = main ] || die "publish from main"
git diff --quiet -- . ':!packaging/homebrew/swivel.rb' ':!CHANGELOG.md' && git diff --cached --quiet \
    || die "commit or put away other changes first"

step "Dating the changelog and committing the cask"
TODAY=$(date -u +%Y-%m-%d)
sed -i '' "s/^## $VERSION (unreleased)$/## $VERSION ($TODAY)/" CHANGELOG.md
grep -q "^## $VERSION ($TODAY)$\|^## $VERSION (20" CHANGELOG.md || die "CHANGELOG.md has no section for $VERSION"
git add CHANGELOG.md packaging/homebrew/swivel.rb
git diff --cached --quiet || git commit -q -m "Release $VERSION"
git push -q origin main

step "Release notes"
NOTES=$(mktemp)
# The version's changelog section, without its heading, then how to install.
awk -v v="$VERSION" '$0 ~ "^## " v " " {on=1; next} /^## / {on=0} on' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<EOF

## Install

- **Download** \`Swivel.dmg\` below, open it and drag Swivel to Applications. It's signed and notarized by Apple.
- **Homebrew:** \`brew install --cask jonathanlotan/tap/swivel\` (this also puts the \`swivel\` command on your PATH).

Apple silicon, macOS 13 or later. Checksum (SHA-256): \`$SHA\`
EOF

step "GitHub release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber --repo "$REPO"
    gh release edit "$TAG" --repo "$REPO" --title "Swivel $VERSION" --notes-file "$NOTES" \
        --target "$(git rev-parse HEAD)" --draft=false --latest
else
    gh release create "$TAG" "$DMG" "$DMG.sha256" --repo "$REPO" --title "Swivel $VERSION" \
        --notes-file "$NOTES" --target "$(git rev-parse HEAD)" --latest
fi
rm -f "$NOTES"

step "Homebrew tap"
gh repo view "$TAP" >/dev/null 2>&1 \
    || gh repo create "$TAP" --public --add-readme --description "Homebrew casks for Swivel, the offline file converter for Mac"
TAP_DIR=$(mktemp -d)
gh repo clone "$TAP" "$TAP_DIR" -- -q
mkdir -p "$TAP_DIR/Casks"
cp packaging/homebrew/swivel.rb "$TAP_DIR/Casks/swivel.rb"
git -C "$TAP_DIR" add Casks/swivel.rb
git -C "$TAP_DIR" diff --cached --quiet || git -C "$TAP_DIR" commit -q -m "swivel $VERSION"
git -C "$TAP_DIR" push -q origin HEAD
rm -rf "${TAP_DIR:?}"

step "Published Swivel $VERSION"
echo "  https://github.com/$REPO/releases/tag/$TAG"
echo "  Check: brew install --cask jonathanlotan/tap/swivel && swivel --version"
