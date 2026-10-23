# 注意：版本号应与 VERSION 文件保持一致
# 更新步骤：1. 修改 VERSION 文件 2. 更新此文件的 version 和 sha256
cask "x-island" do
  version "2.0.5"
  sha256 "ac40a097366b3dc311360a9fb83c54df43f650f63b859970fa3d8e231c9a2eec"

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
