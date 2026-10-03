# 本地编译与安装

## 环境

- macOS 14+ / iOS 17+ 是运行最低版本。
- 双端 Xcode 工程需要完整 Xcode 16.3+、Swift 6.1+、首次解析 SwiftSoup 依赖的网络。
- macOS 单独包装可使用带 macOS SDK 的 Swift Command Line Tools，已在 Swift 6.2.4 上验证。
- 已在 macOS 15.7.7 上安装 Apple 官方 Xcode 16.4（Swift 6.1.2 / iOS 18.5 SDK），iOS 原生 Release 编译通过；连接的 iPhone 运行 iOS 18.5，已启用开发者模式。
- 两个设备的系统版本保持不变，不要求升级系统。Apple 平台下载服务当前返回初始化错误，模拟器运行时尚未安装；真机开发签名、安装和启动已成功，交互测试范围见 [iOS 交付记录](ios-delivery.md)。

安装完整 Xcode，打开一次完成组件安装。在 Xcode > Settings > Locations 选择其 Command Line Tools。`scripts/check-environment.sh` 会检查完整 Xcode、Swift、XcodeGen，缺失时退出非 0；它不会安装软件或改变系统配置。打开已提交工程无需 XcodeGen；只缺 XcodeGen 时仍可用 Xcode 编译。

## macOS 直接安装

解压交付的 universal ZIP，将 `ChasingManga.app` 拖入 `/Applications` 或个人 `~/Applications`，打开即可。应用最低 macOS 14。包内不含漫画数据、书架测试数据或账户。

当前是临时签名的本地构建，未公证。如果另一台 Mac 的 Gatekeeper 限制该包，应从源码自行编译安装，或由维护者完成 Developer ID 签名/公证；不要关闭系统保护。

从源码生成同一包装：

```sh
MANGA_ARCH=universal scripts/package-macos.sh
```

只构建当前架构可省略 MANGA_ARCH。结果在 `release/`，包含应用、ZIP 与 SHA-256。Intel 可执行文件已编译，实际运行验证是在 Apple Silicon 上。

## macOS 使用 Xcode

1. 打开 `ChasingManga.xcodeproj`，选择 `MangaMac`、My Mac。
2. 在 Signing & Capabilities 选择自己的 Team（个人本地运行也可以按 Xcode 的签名配置操作）。项目已启用 App Sandbox 和网络客户端权限。
3. Product > Run。资料保存在应用沙盒的 Application Support/ChasingManga。

命令行构建检查：

```sh
xcodebuild -project ChasingManga.xcodeproj -scheme MangaMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

这里关闭签名只用于编译验证，不是可分发安装包。

## iOS / iPadOS

1. 选择 `MangaIOS` scheme 与已安装的模拟器，Product > Run。
2. 真机先连接设备，在 Signing & Capabilities 选择自己的 Team；按设备提示信任开发者并启用开发者模式。
3. 保留自己设置的签名信息在本机，不提交 Team、证书、账号或描述文件。个人账号的设备安装有效期遵循 Apple 当前规则。

```sh
xcodebuild -project ChasingManga.xcodeproj -scheme MangaIOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

### 生成设备专用 IPA

先在 Xcode 中将 `MangaIOS` 的 Team 设为自己的开发团队，让 Xcode 注册已连接设备并创建开发描述文件。随后运行：

```sh
DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer \
DEVELOPMENT_TEAM=自己的TeamID \
MANGA_DEVICE_UDID=自己的设备UDID \
MANGA_INSTALL=1 scripts/package-ios.sh
```

脚本使用原生设备 SDK 构建 Release，验证代码签名、描述文件有效期和目标设备授权，然后生成 `release/ios/ChasingManga-当前版本-iOS.ipa`、SHA-256 和不含设备标识的 `package-info.json`。没有有效签名或设备授权时停止，不生成未签名安装包。`MANGA_INSTALL=1` 还会通过 USB 安装并尝试启动应用；省略时只打包。完整构建日志保留在本机 `release/ios/build.log`，可能包含签名和设备信息，请勿公开。

IPA 只适用于描述文件授权的设备。免费 Personal Team 的开发描述文件通常有效 **7 天**，到期需重新签名安装；签名信息中的实际有效期为准。[Apple 个人账户说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。该流程不会发布 App Store/TestFlight，也不会升级 Mac 或手机系统。

付费团队的正常联网开发或 Ad Hoc 描述文件通常可达约一年；实际有效期由 Apple 签发的描述文件与证书共同决定。切换 Team 后重新打包，脚本会显示实际到期时间。不要选择仅有效 7 天的离线描述文件。详见 [签名期限说明](source-expansion-0.2.2.md)。

## 工程生成与测试

普通使用者直接打开工程。维护者使用官方 XcodeGen 2.46.0，运行 `scripts/generate-project.sh`；可用 `XCODEGEN_BIN=/absolute/path/xcodegen` 指定路径，版本不符会退出。

```sh
swift run MangaChecks
swift test
xcodebuild -project ChasingManga.xcodeproj -scheme MangaIOS -showdestinations
xcodebuild -project ChasingManga.xcodeproj -scheme MangaMac -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

从 showdestinations 的真实结果选 iOS 模拟器 UDID，再使用 `-destination 'platform=iOS Simulator,id=实际UDID' test`；不要复制不存在的设备 ID。UI 测试仅在 Debug 显式 `--ui-testing` 启动参数下使用本地原创样本。Release 入口忽略此参数。

## 首次使用

首次启动自动检查内置源，进入“发现”即可浏览与跨源搜索。可在“源管理”重试浏览/搜索检查。网站验证时打开该源的可见网页完成正常交互，再重试；会话按来源隔离，不向其他站点共享 Cookie。

自定义源输入站点 URL，建议提供两部作品详情 URL。App 尝试内置方法并验证首末章节和图片；只给一部作品时标记有限验证。结构未知的网站会保留不支持状态，不能保证任意网站都自动成功。

搜索或浏览作品→选择阅读来源→章节→阅读。仅阅读能力的来源可以在发现页选择已验证作品，或点击链接图标输入来源内的作品详情网址；自定义源样本必须在配置域名和子路径范围内。收藏需要点击“加入书架”。在作品详情点击“关联其他来源”，可跨源搜索、从已打开作品手动选择别名，或输入作品详情链接核对；多来源关联和跨源续读由用户确认，不会默默换源。章节页可筛选、排序、批量选择下载，准备与传输可取消/暂停。下载完成会校验清单、图片与摘要，删除源不会删除已下载正文。缓存清理不删除离线章节。

通知默认关闭。在设置中主动开启时才请求权限；拒绝后仍可查看更新页。iOS 后台执行受系统调度影响，强制退出后不承诺继续下载/更新。macOS 每 30 分钟检查只在 App 运行时进行。
