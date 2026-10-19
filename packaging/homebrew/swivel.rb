# The Homebrew cask, kept here and copied to Casks/ in jonathanlotan/homebrew-tap.
# `make release` fills in the version and checksum.
cask "swivel" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/jonathanlotan/Swivel/releases/download/v#{version}/Swivel.dmg"
  name "Swivel"
  desc "Offline file converter opened by tapping a key while dragging"
  homepage "https://github.com/jonathanlotan/Swivel"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "Swivel.app"
  binary "#{appdir}/Swivel.app/Contents/Helpers/swivel"

  zap trash: "~/Library/Preferences/io.github.jonathanlotan.Swivel.plist"
end
