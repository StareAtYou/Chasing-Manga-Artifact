# v0.2.2 来源扩充与签名期限

继续采用原有独立解析器、源会话隔离及本地存储架构。新增来源自动补入旧安装的源列表，不覆盖现有来源的启用状态、绑定、删除记录或书架。网站是否可用取决于其当时状态和网络；一次样本验证不代表所有作品永久可读。

## 筛选

- MangaBZ：https://www.mangabz.com/。中文站点，通过公开 `chapterimage.ashx` 获取实际图片地址。读取固定字符串数据模板，不执行返回脚本。保留原站付费与地区限制。
- ComicFury：https://comicfury.com/。作者发布的英文原创漫画平台。使用平台同域阅读器，按作品遍历分页目录，并限定当前漫画页的正文图片。
- Dinosaur Comics：https://www.qwantz.com/。Ryan North 的英文原创系列。读取官方完整存档中真实存在的期号，按最早到最新排列；搜索匹配系列名或作者，不提供每一期全文搜索。

漫画柜的详情和页面可访问，但其阅读数据需要进一步验证；COLAMANGA 的详情请求返回 523；其他部分候选站点返回验证页面、TLS 连接失败或服务错误。本版不将这些未验证候选加入内置池。

2026-10-03 在 macOS 15.7.7 上执行真实正文探针：

| 来源 | 实测作品目录 | 正文验证 |
| --- | --- | --- |
| MangaBZ | 一拳超人 578 章、篮球少年王 243 章 | 两部作品首末章节的首末 JPEG 解码通过；一拳首章完整获取 208 页地址，末章 17 页，重用接口预加载的下一页地址 |
| ComicFury | Unbound 247 页 | 三页完整目录，首末章节 JPEG 解码通过 |
| Dinosaur Comics | 4510 期 | 官方完整存档，首末 PNG 解码通过 |

ComicFury 第二个样本 Bugs 目录 500 页，首章 PNG 解码成功，但最新 Ending 3 在平台阅读器中明确提示媒体格式不支持。本版将这种状态提示为“此章的媒体格式仅支持在原站阅读”，不误报为普通图片解析失败，不自动跨来源请求。ComicFury 的内置图片解析不覆盖这类媒体。原始探针含此失败记录，见 [探针目录](source-probes)。本轮只解码抽样首末图片，未下载或验证每章的每张图片，也不能替代手机实际网络下的阅读验收。

27 个原生 Swift Testing 测试入口、149 个共享检查通过。来源升级与 URL 规范化问题均先复现失败，再修复通过。双端使用 Xcode 16.4、Swift 6.1 与对应设备 SDK；macOS 包含 arm64 / x86_64，iOS 包最低 iOS 17，使用 iOS 18.5 SDK。15 张 iOS 图标检查通过。iPhone 当前显示断开连接，无法覆盖安装或验收新版手机正文；未升级两台设备系统。

## IPA 期限

当前本地签名属于 Personal Team，Apple 签发的设备开发描述文件有效期为 7 天。证书期限不能延长描述文件期限，修改日期也不会获得更长的有效签名。

如已有 Apple Developer Program 付费团队，可在 Xcode 的 MangaIOS → Signing & Capabilities 中选择该团队，使用正常联网开发或 Ad Hoc 描述文件，再重新打包。通常可获得约一年期限，实际安装有效期受描述文件和签名证书共同限制。不要选择付费账户下也只有 7 天的离线描述文件。脚本会输出 Apple 实际签发的到期日期和剩余时间；不能预设一年授权。

来源：[Apple 个人账户与团队](https://developer.apple.com/help/account/basics/about-your-developer-account)、[Apple 描述文件更新说明](https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates)、[Apple 描述文件签名原理](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。

切换 Team 可能改变应用标识权限，安装前应保留设备备份并沿用原应用的 Bundle ID；若无法覆盖安装，应先完成资料迁移再卸载。无需升级 macOS 15.7.7 或 iOS 18.5。
