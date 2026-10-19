# Releasing Swivel

`make release` builds `Swivel.dmg`, signed with Developer ID and notarized by Apple, so it opens
without Gatekeeper warnings. The `swivel` command is inside the app, at
`Swivel.app/Contents/Helpers/swivel`. There's no auto-updater (it would need the network);
people update with Homebrew or by downloading the new DMG.

## One-time setup

1. **Join the Apple Developer Program** ($99 a year) at
   [developer.apple.com/programs](https://developer.apple.com/programs/). Approval usually
   takes a day or two.
2. **Create a Developer ID Application certificate.** In Xcode: Settings › Accounts › your
   team › Manage Certificates › + › Developer ID Application. It goes into the login keychain.
   Check with:
   ```bash
   security find-identity -v -p codesigning
   ```
   The line should read `Developer ID Application: Your Name (TEAMID)`.
3. **Save notarization credentials** in the keychain. Make an app-specific password at
   [account.apple.com](https://account.apple.com) › Sign-In and Security, then run this and
   answer its prompts:
   ```bash
   xcrun notarytool store-credentials swivel-notary --apple-id you@example.com --team-id TEAMID
   ```
4. **Create the Homebrew tap**, a public repository named `homebrew-tap`, with a `Casks` folder.
   ```bash
   gh repo create jonathanlotan/homebrew-tap --public --description "Homebrew casks for Swivel"
   ```

## Each release

1. Set the version in two places: `MARKETING_VERSION` (and bump `CURRENT_PROJECT_VERSION`) in
   `Converter/project.yml`, and `version` in `Packages/ConverterCore/Sources/swivel/CLI.swift`.
   `make release` stops if they differ.
2. Update `CHANGELOG.md`, commit, and run the tests: `make test`.
3. Build:
   ```bash
   SWIVEL_TEAM_ID=TEAMID make release
   ```
   It takes a few minutes, mostly waiting for Apple's notary service, and ends by printing the
   DMG's checksum. It also writes that version and checksum into `packaging/homebrew/swivel.rb`.
4. Check the result:
   ```bash
   spctl -a -vvv -t install ~/Library/Caches/Converter/release/Swivel.dmg
   ```
   It should print `accepted` and `source=Notarized Developer ID`. For a real test, download
   the DMG with a browser on another Mac or a fresh VM (so it's quarantined), open it, drag
   Swivel to Applications and open it: no warning should appear.
5. Publish it. Keep the asset named `Swivel.dmg`: the README's download button links to
   `releases/latest/download/Swivel.dmg`.
   ```bash
   gh release create v1.0.0 ~/Library/Caches/Converter/release/Swivel.dmg \
     ~/Library/Caches/Converter/release/Swivel.dmg.sha256 --title "Swivel 1.0.0" --notes-file notes.md
   ```
6. Update the tap: copy `packaging/homebrew/swivel.rb` to `Casks/swivel.rb` in
   `jonathanlotan/homebrew-tap`, commit and push. Then check:
   ```bash
   brew install --cask jonathanlotan/tap/swivel && swivel --version
   ```
7. Commit the updated `packaging/homebrew/swivel.rb` here too.

## The official Homebrew cask

`homebrew/cask` takes a self-submitted app once the repository is at least 30 days old and has
225 stars, 90 forks or 90 watchers (the
[acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy)). For Swivel that's
**18 November 2026** at the earliest. Then `brew install --cask swivel` works without the tap.
Submit with `brew bump-cask-pr` or a pull request that adds `Casks/s/swivel.rb`.
