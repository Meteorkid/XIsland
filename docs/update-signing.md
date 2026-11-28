# 更新签名密钥

X Island 2.3.4 起，应用内更新不再依赖 Developer ID Team ID，而是验证独立的 Ed25519 更新清单签名。

## 文件位置

- 公钥：`Config/UpdateSigningPublicKey.txt`，随源码提交，构建时写入 App 的 `XIslandUpdatePublicKey`。
- Key ID：`Config/UpdateSigningKeyID.txt`，构建时写入 `XIslandUpdateKeyID`。
- 私钥：默认在 `~/.xisland/update-signing/xisland-update-2026-11.private.key`，权限 `0600`，**不进入仓库、不上传 CI**。

## 发布流程

1. 构建并打包 DMG。
2. 运行 `bash Scripts/sign-update.sh <version> <dmg>`。
3. 同时上传 DMG、`XIsland-<version>.manifest.json`、`XIsland-<version>.manifest.sig`。
4. 运行 `bash Scripts/preflight-release.sh --require-dmg`，确认清单字段、DMG SHA256 和 Ed25519 签名一致。

## 备份与轮换

私钥丢失后无法继续签出旧版本可验证的更新。备份私钥时应使用加密介质，不要复制到仓库或云端明文目录。

轮换密钥的步骤：

1. 生成新密钥对，更新 `Config/UpdateSigningPublicKey.txt` 和 `Config/UpdateSigningKeyID.txt`。
2. 发布一个包含新公钥的版本；该版本仍需手动安装一次。
3. 从该版本起，旧私钥不能再签出可被新版本接受的清单。

公钥可以公开；私钥只用于发布机签名。
