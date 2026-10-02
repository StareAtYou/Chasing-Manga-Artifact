# 本地编译与安装

## 环境

- macOS 14+ / iOS 17+ 是运行最低版本。
- 双端 Xcode 工程需要完整 Xcode 16.3+、Swift 6.1+、首次解析 SwiftSoup 依赖的网络。
- macOS 单独包装可使用带 macOS SDK 的 Swift Command Line Tools，已在 Swift 6.2.4 上验证。
- 当前机器只有 Command Line Tools；macOS 普通 Release 应用已构建并运行验证。iOS SDK、原生测试运行时和设备验收仍缺失。

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
