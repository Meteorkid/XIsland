cask "x-island" do
  version "1.3.5"
  sha256 "cc8736920f4058fe6d4b157cc3b60ef13088e62091909e8c15ccdec8df3e7788"

  url "https://github.com/Meteorkid/XIsland/releases/download/v#{version}/XIsland-#{version}.dmg",
      verified: "github.com/Meteorkid/XIsland/"
  name "X Island"
  desc "Dynamic Island-style AI coding agent control panel"
  homepage "https://github.com/Meteorkid/XIsland"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "X Island.app"

  zap trash: [
    "~/.xisland",
    "~/Library/Preferences/dev.xisland.app.plist",
  ]
end
