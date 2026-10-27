# 注意：版本号应与 VERSION 文件保持一致
# 更新步骤：1. 修改 VERSION 文件 2. 更新此文件的 version 和 sha256
cask "x-island" do
  version "2.0.14"
  sha256 "9a67fefa437b500147f7a672ce230cabc47bebbb347ee3151b92cba69d4660d7"

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
