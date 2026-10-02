# 本地编译与安装

## 环境

- macOS 14+ / iOS 17+ 是运行最低版本。
- 编译需要完整 Xcode 16.3+、Swift 6.1+、首次解析 SwiftSoup 依赖的网络。
- 当前实现机器仅有 `/Library/Developer/CommandLineTools`；原生应用构建和实机验收没有完成。

安装完整 Xcode，打开一次完成组件安装。在 Xcode > Settings > Locations 选择其 Command Line Tools。`scripts/check-environment.sh` 会检查完整 Xcode、Swift、XcodeGen，缺失时退出非 0；它不会安装软件或改变系统配置。打开已提交工程无需 XcodeGen；只缺 XcodeGen 时仍可用 Xcode 编译。

## macOS

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

到“发现”→“源管理”，检测内置源的浏览/搜索能力。网站验证时打开该源的可见网页完成正常交互，再重试；会话按来源隔离，不向其他站点共享 Cookie。

自定义源输入站点 URL，建议提供两部作品详情 URL。App 尝试内置方法并验证首末章节和图片；只给一部作品时标记有限验证。结构未知的网站会保留不支持状态，不能保证任意网站都自动成功。

搜索或浏览作品→选择阅读来源→章节→阅读。收藏需要点击“加入书架”。多来源关联和跨源续读由用户确认，不会默默换源。下载完成会校验清单、图片与摘要，删除源不会删除已下载正文。缓存清理不删除离线章节。

通知默认关闭。在设置中主动开启时才请求权限；拒绝后仍可查看更新页。iOS 后台执行受系统调度影响，强制退出后不承诺继续下载/更新。macOS 每 30 分钟检查只在 App 运行时进行。
