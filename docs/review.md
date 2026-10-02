# 独立审查与一轮修复

2026-10-02，一位未参与实现的 gpt-6-astra 审查者读取 `522cc5e..e18a7e2` 全分支、批准的设计/计划与执行记录；结论为 9 项 Important、无 Critical / Minor。实现者确认严重性后一次修复，未再次派发审查。原生平台验收仍待完成，不据此宣称双端可发布。

## 发现与证据

| 发现 | 修复与验证 |
| --- | --- |
| 重复选择当前阅读模式后进度被冻结 | 相同模式立即返回；`sameReaderModeKeepsPositionEnabled` 原行为 FAIL→PASS，Mac 重新选择逐页后下一页仍从 1/4 到 2/4 |
| 编辑页的旧来源快照回退版本并恢复旧绑定 | 数据库检查当前版本；只编辑用户字段、保留检测元数据、保存后刷新编辑快照；`staleSourceCannotRestoreOldBinding` 原行为 FAIL→PASS，`editPreservesCurrentParserMetadata` 新 API RED→GREEN |
| 下载恢复时旧序号使文件与刷新后的 PageID 错配 | 按当前 PageID 重建序号、离线读取按 ID 查文件；`offlineReorderMapsFilesByIdentity` 原行为 FAIL→PASS |
| 外站样本可验证错误来源、自动发现忽略来源子路径 | 检测前校验样本范围；文档请求及返回 URL、作品/章节身份与范围都验证；`foreignSamplesNeverBind` 原行为 FAIL→PASS，`sourceSubpathScopeHasSegmentBoundary` 新 API RED→GREEN |
| WebKit Cookie 扁平化丢失 path/expiry 限制 | 保存 cookie 元数据，请求/重试/重定向按目标重新选择；`cookiesHonorPathExpiryAndRedirect` 新 API RED→GREEN；生产 URLSessionTransport 使用 scoped transport |
| Mac 方向键按单页移动双页、滚动只保存了进度 | 按显示组计算目标、滚动请求定位页面、恢复完成才响应、图片就绪自动聚焦；`keyboardMovesWholeSpread` / `scrollKeyboardRequestsVisibleMovement` 新 API RED→GREEN；实际 Mac 方向键最初无变化，聚焦/快捷键修复后双页 2/4→4/4，滚动条 0→0.29324，RTL Right 4/4→2/4、Left 2/4→4/4 |
| 仅阅读能力的自定义来源没有进入作品的入口 | 发现页可选已验证作品与来源详情网址，检测样本可选；`readableOnlySourceCanOpenWorkURL` 新 API RED→GREEN |
| 歧义预览丢失 Referer/访问上下文、竞争解析器缓存冲突 | 保留完整 PageResource request，检测批次/解析器隔离预览缓存；`previewsRetainRefererAndDistinctIdentity` 新 API RED→GREEN |
| 原生 UI 测试角色/标识错误且不等待图片就绪 | 显式章节 Button，移除 reader 祖先标识遮盖，Mac popup/menu 与 iOS Button 分别选择并等待 reader-ready；手动原生辅助功能树从找不到 chapter-0 到显示 chapter-0 Button/page-zoom/reader-ready，点击与分页通过。XCTest 自身未运行，待完整 Xcode |

四个原行为检查首次为 0/4；全部 11 个新检查最终为 11/11。其余新 API 检查首次因接口不存在而编译失败，不能说它们证明了旧实现全部对应行为的运行结果。共享全套最终为 93/93。保留 [原行为失败记录](review-evidence/original-behavior-red.txt)、[最终全部检查结果](review-evidence/final-shared-checks.txt) 与 [原生环境限制](review-evidence/native-environment.txt)。Mac 原生操作使用 CLT 链接真实 App 入口与共享模块的 Debug 本地原创样本；不替代签名沙盒、原站界面、iOS 或原生 XCTest。

## 审查者未判断的范围

原生 iOS/沙盒/通知/后台生命周期、长图清晰度/整体内存、网站地区/真实过期/双作品认证、在线 CI、未纳入的同步/任意源/付费访问与后台定时保证，都已按开发预览状态记录为决策和验收边界，详见 [执行记录](implementation-ledger.md) 中所有 `Final: Ruling:` 与 [验收记录](verification.md)。没有延期 Minor。
