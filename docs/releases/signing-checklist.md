# 正式签名发行清单

> 状态：**未执行**。本项目当前没有 Developer ID 证书与公证凭据，因此本轮只整理清单，
> 不修改发布流水线。以下每一项都需要在具备证书后逐条验证。

## 一、现状

| 能力 | 现状 | 位置 |
|---|---|---|
| 下载完整性校验 | ✅ 已有 SHA256 比对 | `Casks/x-island.rb`、更新流程 |
| 更新失败回滚 | ✅ 已有 | `Managers/AppUpdater.swift` |
| 代码签名 | ❓ 未确认（本地构建通常为 ad-hoc） | — |
| 公证（notarization） | ❌ 无 | — |
| 更新元数据签名 | ❌ 无 | — |
| Gatekeeper 首启验收 | ❌ 未纳入验收 | — |

## 二、需要准备的三样东西

1. **Developer ID Application 证书**
   - 用途：签发 .app 与内嵌二进制（`di-bridge`、`XIslandUITestDriver`）
   - 注意：`di-bridge` 是独立可执行文件，**必须单独签名**，否则主 app 公证会因
     "包含未签名可执行文件"被拒

2. **Apple 公证凭据**
   - App Store Connect API Key（推荐）或 Apple ID + App 专用密码
   - 用途：`notarytool submit --wait`

3. **Sparkle EdDSA 私钥**（若使用 Sparkle 自动更新）
   - 公钥需写入 Info.plist
   - 私钥不得进仓库；`scripts` 中应有"签名为空则中止"的断言

## 三、建议的执行顺序

```
1. 清理构建产物 → 重新归档
2. 签内嵌二进制（先子后父，避免父签名被后续步骤破坏）
3. 签 .app
4. codesign --verify --deep --strict
5. 打 DMG → 签 DMG
6. notarytool submit --wait → stapler staple
7. spctl -a -vvv 校验 Gatekeeper 放行
8. 生成 SHA256 → 更新 Cask 与更新源
```

**顺序要点**：先签内层再签外层。反过来会因外层签名覆盖内层签名而导致公证失败。

## 四、必须纳入验收的三项

1. **Gatekeeper**：在未安装过本 app 的机器上首次打开，不应出现"无法验证开发者"
2. **钥匙串**：授权相关凭据（`MeteorLicenseCore`）读写不应触发重复授权弹窗；
   签名主体变更会让系统把它当作新应用，已有授权失效——升级路径需要实测
3. **自动更新**：旧版本 → 新版本升级后，签名主体一致（Team ID 不变），
   否则会二次弹授权

## 五、为什么本轮不做

- 缺少 Developer ID 证书与公证凭据，无法产生可验证的产物
- 发布流水线改动无法在没有证书的情况下测试，改了等于埋雷

需要时把证书导入钥匙串，再按上面顺序执行；届时可把第 3 步起写成 `Scripts/release-signed.sh`。
