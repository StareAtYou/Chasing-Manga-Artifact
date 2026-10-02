# 追漫 · Chasing Manga

Swift / SwiftUI 原生漫画阅读器，支持 iOS 17+ 与 macOS 14+，每端保存自己的书架、历史、下载与设置。当前为开发预览：共享服务和 macOS UI 模块可构建，完整双端应用验收尚未完成。

## 功能

- 内置漫画站、瓜子漫画、DM5 的独立适配器；访问限制与解析失败分别提示。
- 自定义网址与作品样本：依次尝试内置解析器，验证目录和真实图片后绑定方法与版本；有限样本或歧义需要明确处理。
- 多源搜索、手动关联/解除关联、用户选择阅读来源与跨源续读候选。
- 书架、历史、更新、离线下载；通知默认关闭。
- 纵向滚动、逐页、左右阅读方向、macOS 双页、缩放与页内进度。
- 优先当前页、有限预加载、独立缓存/离线目录，过期资源重新取地址。

## 编译运行

直接打开 `ChasingManga.xcodeproj`，选择 `MangaMac` 或 `MangaIOS` scheme。需要完整 Xcode 16.3+（Swift 6.1+）；iOS 真机在 Signing & Capabilities 中选择自己的 Team。详见 [安装说明](docs/build-and-install.md)。无需服务器、登录、同步服务或 XcodeGen。

```sh
swift run MangaChecks
swift build --target MangaUI
```

只有 Command Line Tools 时，可执行这两项共享验证；不能替代原生应用构建、Swift Testing 或设备验收。重新生成工程需 XcodeGen **2.46.0**：`scripts/generate-project.sh`。

## 来源状态和验证

见 [真实来源验证](docs/source-validation.md) 和 [验收记录](docs/verification.md)。每个源、每个能力分别验证。首次启动只登记候选源；在“源管理”中检测浏览/搜索能力，或添加作品样本验证阅读。不承诺任何网站所有漫画永久免费或持续可用。漫画站搜索当前遇到安全验证；部分 DM5 作品存在地区/付费限制。

网站正文地址来自正常公开页面或其正常请求。不会执行用户插件、生成任意解析脚本或绕过登录/付费限制。HTTP 自定义源也可使用，网址与内容传输的安全性取决于该来源；优先使用 HTTPS。

长图采用 ImageIO 有上限的缩略解码后分块显示，最大解码维度 4096。超长图可能降低清晰度；内存限制不等同于整个 App 的实测峰值。含 Cookie 的下载使用可控制重定向的前台传输，应用挂起后可能暂停。

## 开源

代码采用 [MIT](LICENSE)；网站漫画内容不随本项目授权或分发。依赖许可见 [第三方声明](THIRD_PARTY_NOTICES.md)，解析器贡献规范见 [CONTRIBUTING](CONTRIBUTING.md)。本地已具备开源工程结构，尚未发布远程仓库或上架。
