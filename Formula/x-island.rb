cask "x-island" do
  version "1.0.0"
  sha256 :no_check

  url "https://github.com/user/xisland/releases/download/v#{version}/X-Island-#{version}.dmg",
      verified: "github.com/user/xisland/"
  name "X Island"
  desc "Dynamic Island-style AI coding agent control panel"
  homepage "https://github.com/user/xisland"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "X Island.app"

  zap trash: [
    "~/Library/Preferences/dev.xisland.app.plist",
    "~/.xisland"
  ]
end
