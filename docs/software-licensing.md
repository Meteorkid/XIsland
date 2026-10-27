# XIsland 软件授权

自 2.0.13 起，XIsland 使用 Meteor Store 的在线授权协议，与 XNook 共用 `MeteorLicenseCore`。版本说明见 [2.0.13 更新说明](releases/2.0.13.md)。

## 用户行为

- 下载无需购买。首次启用联网登记本机的 14×24 小时试用，换渠道下载与重装不重置服务器记录。
- 月度、年度、永久激活码通过 `/api/software-licenses/activate` 兑换与本机绑定的签名租约。
- 每份产品授权最多 3 台设备。解绑本机须联网，成功后停止主要功能；也可在网站账户页管理设备。
- 签名租约最多允许离线 7 天，且不会越过试用或订阅到期时间。永久授权无需续费，但仍需定期联网核验设备状态。
- 客户端每分钟本地重验、在签名截止时间设单次定时器，并在应用激活与系统唤醒时联网核验；运行期间每 15 分钟尝试刷新。明确撤销会立即停止放行，网络故障只保留尚未过期的有效租约。
- 到期会关闭灵动岛、socket、配额轮询、自动接入修复与会话监控。设置中的授权、历史导出和关于页保留，不删除用户数据。重新激活会恢复运行服务。

## 协议及配置

服务端默认 `https://www.imagentx.top`，接口为 `POST /api/software-licenses/{trial,activate,refresh,deactivate}`。公钥是 32 字节 Ed25519 原始公钥的 Base64；私钥不得进入源码或安装包。

构建环境变量：

- `SOFTWARE_LICENSE_PUBLIC_KEY`：必须提供的公钥；写入 `Info.plist` 的 `SoftwareLicensePublicKey`。
- `SOFTWARE_LICENSE_API_BASE_URL`：可选 HTTPS 服务地址；写入 `SoftwareLicenseAPIBaseURL`。
- `X_ISLAND_BUILD_DIR`：可选、任务专用的绝对构建目录，避免覆盖原 `.build` 安装包。
- `X_ISLAND_SKIP_BRIDGE_INSTALL=1` 与 `X_ISLAND_SKIP_PATH_CONFIGURE=1`：候选构建必须使用，避免安装 bridge 或修改 shell 配置。

`Scripts/build.sh` 在写入安装包前验证公钥和服务地址。普通 `swift build` 不需要密钥，但这样的裸二进制不具备试用/激活配置，不能当作正式可售卖安装包。

设备身份只上传硬件 UUID 的 SHA-256 哈希；系统无法提供硬件 UUID 时，使用钥匙串持久化随机身份。服务令牌、签名租约和单调推进的校验时间保存在本机钥匙串，测试通过独立内存存储注入。

无授权的隔离 UI fixture 只在 Debug 构建或 XCTest 进程中可用。正式 Release 安装包即使带 `--ui-test-mode` 也不能借此启动监控服务。

## 验证与发布边界

运行 `swift test` 验证协议、启动门禁、锁定与恢复；运行 `swift build` 验证客户端编译。跨语言验签与真实网站服务由发布前集成验收覆盖。

网站迁移、正式签名公钥配置、真实付款发码、三台设备及换机验收完成后，才能发布新版本安装包。网站和 GitHub 分发必须使用同一已验收构建。旧安装包不会因为网站变更自动获得新授权限制。

共享核心的权威开发来源为 XNook 基线工作区 `Sources/MeteorLicenseCore`；两个仓保留相同文件并各自构建，不依赖兄弟仓目录。
