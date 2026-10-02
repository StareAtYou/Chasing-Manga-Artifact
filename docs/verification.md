# 验收记录

日期：2026-10-02。机器为 Apple Silicon、macOS 15.7.7、Swift 6.2.4；Developer 路径 `/Library/Developer/CommandLineTools`，没有完整 Xcode。这里区分自动服务检查、在线请求、原生界面预览与未执行的平台验收。

## 已通过

| 项目 | 结果与范围 |
| --- | --- |
| `swift run MangaChecks` | 82/82，涵盖身份、数据库、网络隔离、检测绑定、三站 fixture、搜索关联、图片、离线完整性、更新、导航、阅读与完整流程 |
| `swift build --target MangaUI` | macOS SDK 下成功；包括 Core、Platform 与 SwiftUI 界面 |
| Mac App 入口 typecheck | Debug 与主入口可编译；不等同于 Xcode app target 构建 |
| XcodeGen 2.46.0 | 已生成两个 App 与两个 UI test targets/shared schemes；官方 zip SHA256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806` |
| plist / pbxproj | `plutil -lint` 通过；不是平台链接验证 |
| `git diff --check` | 无输出，退出 0 |
| 三源在线 probe | 全部 readingVerified=true；每站一部作品首/末章代表图片真实解码；详情见 source-validation.md、source-probes/ |
| Mac 原生预览 | 用 CLT swiftc 链接真实 Mac App 入口与共享模块成临时 `.app`，通过 CUA 实际操作作品→选源→章节→滚动图片→逐页→下一页→双页；看到页码 1/4→2/4，双页保留第 2 页 |

Mac 预览实际发现章节 List 的 plain Button 不响应点击，改为 borderless 与完整点击区域后，相同坐标进入章节并显示图片。UI test 中保留章节进入阅读断言。此预览只使用显式 Debug 本地原创样本，不替代原站验证、签名/沙盒验收或 iOS 测试。

## 环境未执行 / 尚未通过验收

- `swift test`：本机没有 Swift Testing；已加入明确编译门槛，避免没有测试运行却返回成功。完整 Xcode 下复用同一组行为检查，尚未运行。
- 两条 `xcodebuild … build CODE_SIGNING_ALLOWED=NO` 与 macOS `… test`：均退出 1，具体错误为“xcodebuild requires Xcode … CommandLineTools”。没有 BUILD SUCCEEDED 或原生 XCTest 成功记录。
- iOS `-showdestinations` 同样失败；未获取实际模拟器 UDID，因此没有虚构模拟器 test 命令或结果。
- iOS / iPadOS 启动、触控缩放、滚动页内恢复、方向切换、通知允许/拒绝、后台传输与 BGAppRefresh 过期、签名安装：待完整 Xcode 与设备。
- macOS 鼠标/触控板缩放、长图细节、跨模式滚动恢复、关机/重开、真实通知权限、网络中断、原生下载后台回调与沙盒网络：还需完整平台验收。已有服务回归不代替这些交互。
- 每站两作品各两章、真实签名过期恢复未完成，不能提升到完整源级验证。部分 DM5 内容明确地区受限；漫画站搜索先安全验证、本次 HTTP 500。
- CI 工作流已配置，未推送仓库，尚无在线 CI 结果。远程开源发布和上架未进行。

## 性能边界

本次三站 CLI 探针并行请求、正常系统网络环境（网络代理/链路未标定）：瓜子整个探针 17.36 秒，DM5 6.30 秒，漫画站 8.37 秒；这是含浏览/搜索/目录/代表图片的整段探针时间，不是 App 首图或翻页耗时。CLI 最大 resident set 分别约 36.3 / 36.7 / 83.7 MiB；漫画站使用 WebKit 子进程，该值不能代表完整 WebKit/App 总内存。

图片管线限制缓存字节与缩略解码维度，长图超出 4096 时降低采样率。真实首图时间、连续翻页等待、超长图峰值、WebKit 子进程、iOS memory pressure 的完整测量仍待设备验收；不能把 64 MiB 解码缓存预算宣称为总进程上限。

后续按设备型号、系统、分辨率、网络、冷/热缓存分别记录首图时间、翻页耗时、总进程峰值与长图清晰度。当前状态是开发预览，不能称双平台完整首版已经交付。
