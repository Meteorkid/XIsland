# 注意：版本号应与 VERSION 文件保持一致
# 更新步骤：1. 修改 VERSION 文件 2. 更新此文件的 version 和 sha256
cask "x-island" do
  version "2.0.8"
  sha256 "43ff357435920ae923b4492a3fd633c34e6ae40a0d94033038fa6b3d910283c6"

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
