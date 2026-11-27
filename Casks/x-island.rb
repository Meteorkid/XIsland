# 注意：版本号应与 VERSION 文件保持一致
# 更新步骤：1. 修改 VERSION 文件 2. 更新此文件的 version 和 sha256
cask "x-island" do
  version "2.3.1"
  sha256 "7dcdd9b8c703bebc0e041d6ec9b143900259dae3ac19bb0f2220d539196fb7ce"

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
