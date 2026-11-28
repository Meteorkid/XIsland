# 注意：版本号应与 VERSION 文件保持一致
# 更新步骤：1. 修改 VERSION 文件 2. 更新此文件的 version 和 sha256
cask "x-island" do
  version "2.3.3"
  sha256 "de132bae60292ee23cb1158fd065de9e99c39a68f6c7beb3699d662f8472e884"

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
    "~/Library/Application Support/XIsland",
    # 2.2.0 及更早版本使用的通用 SwiftData 路径；迁移失败或用户回退时可能仍存在。
    "~/Library/Application Support/default.store",
    "~/Library/Application Support/default.store-wal",
    "~/Library/Application Support/default.store-shm",
    "~/Library/Application Support/HistoryBackups",
  ]
end
