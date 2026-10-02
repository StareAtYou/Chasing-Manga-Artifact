# iOS 原生构建与设备安装记录

2026-10-02。Mac 为 Apple Silicon / macOS 15.7.7，验收设备为 iPhone / iOS 18.5。两个设备的系统均保持原版本，没有升级。

使用 Apple 官方 Xcode 16.4（16F6）、Swift 6.1.2、iOS 18.5 SDK 构建 Release。应用最低 iOS 17；macOS 目标最低 macOS 14，并已用同一 Xcode 的 macOS 15.5 SDK 原生构建通过。22 组共享 Swift Testing 原生测试通过。原有 macOS universal 交付包保留。

## 已验证

- iOS 原生 Release 编译、链接、应用验证成功，包含主屏图标与共享功能模块。
- 使用用户的 Apple Development 签名，描述文件包含验收设备；设备标识、签名账户与具体有效期保留在本地交付信息中。
- IPA 解压完整性通过；解压出的 `.app` 通过 `codesign --verify --deep --strict`，可执行文件与已安装构建一致。
- 通过 CoreDevice USB 安装成功，设备应用清单包含“追漫”0.2.0/build 2。
- 用户完成开发者信任后，CoreDevice 启动应用成功；随后设备进程清单确认应用仍在运行。
- 最后再次检查：Mac 15.7.7、iPhone 18.5、手机开发者模式开启。

本地安装包为 `ChasingManga-0.2.0-iOS.ipa`，实际校验值保留在本地交付目录，不随源码公开。包内不包含测试书架、漫画图片或用户资料。设备专用开发描述文件必然包含设备授权信息，该 IPA 应作为私人安装包保管；源码不含账户、证书、Team ID 或设备标识。

## 安装与再次构建

当前手机已安装，不需要再次解压或复制文件。首次信任通过 iPhone“设置 → 通用 → VPN 与设备管理”确认自己的开发者账户。开发签名到期后，使用 `scripts/package-ios.sh` 重新签名、打包、安装，详见 [编译安装](build-and-install.md)。该 IPA 只授权当前设备，不是任意手机通用的 App Store 包。

## 验收边界

原生编译、签名、安装、启动与持续进程检查已完成。iOS 18.5 模拟器下载仍受 Apple MobileAsset 服务初始化错误阻塞，因此没有宣称 iOS XCTest UI 测试通过。触控缩放、阅读页内恢复、通知权限、后台执行与内存压力仍需针对真机继续交互验收；macOS 已有的真实三源阅读结果不能替代 iOS 交互测试。
