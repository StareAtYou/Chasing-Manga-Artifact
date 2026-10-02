# Manga Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现公开开源的 macOS / iOS 本地追漫应用，支持多源搜索、用户选择来源、自定义源自动绑定、阅读、离线下载及更新提醒。

**Architecture:** SwiftPM 管理共享的业务核心、Apple 平台服务和 SwiftUI 界面。两个原生应用入口注入本机 SQLite 存储、解析器注册表和平台服务，不依赖同步服务器。先验证真实漫画源的完整链路，再接入完整产品界面。

**Tech Stack:** Swift 6（工具链最低 6.1），SwiftUI，Foundation / URLSession，WebKit，ImageIO，SQLite / GRDB，SwiftSoup，UserNotifications，BackgroundTasks；XcodeGen 生成双平台 Xcode 工程。

**Spec:** `docs/superpowers/specs/2026-10-02-manga-reader-design.md`，用户已确认。

## Global Constraints

- 最低系统版本：iOS 17、macOS 14；iPhone 优先，iPad 提供自适应布局。
- 两端都是本地单机模式；不提供账户、服务器或双端同步。
- 同一漫画可以关联多个来源，由用户选择来源后进入阅读；不自动替换正在阅读的内容。
- 默认阅读模式为竖向滚动，默认翻页方向为从左向右；按作品保存用户的阅读偏好。
- 阅读器支持左右翻页、方向切换和 macOS 双页；首页单独显示，末尾落单页面独立显示。
- 详情、章节和正文图片验证通过才可标为可阅读；搜索能力独立验证。
- 自动缓存与离线下载分开，清理缓存不能删除下载；只有完整且可读的章节标为已下载。
- 更新提醒默认关闭；开启应用时检查更新，提供手动刷新；后台检查由系统安排。
- 自定义源输入名称、网站 URL 和可选样本 URL；首版无用户脚本编辑器、远程可执行插件或源市场。
- 首批候选：漫画站、瓜子漫画、DM5；不能用模拟图片或其他源替代指定源的真实验收。
- 暂不实现自动裁边、跨页识别、自动滚动、翻译、社交和推荐算法。
- 不把当前未解决的 403 或动态接口标为已解决；不承诺测量前的加速比例。

## Review Focus

- 两个源中的同一章节 ID、同域不同子路径：身份与进度不能碰撞。任务 1、2。
- 已取消的探测/搜索在新请求之后返回：旧结果不能覆盖绑定或当前结果。任务 5、10。
- HTTP 200 返回广告、验证 HTML 或损坏图片：不能误绑解析器或标记下载完成。任务 4、5、11、12。
- 下载重启时图片签名变化或文件缺页：按稳定页身份恢复，缺页继续失败而非显示完成。任务 12。
- 改选来源时目录拆章、缺章或顺序变化：只推荐续读候选，由用户确认，原进度保留。任务 10、15。

---

## 文件与依赖划分

根目录 `Package.swift` 在任务 1 建立 `MangaCore` 与测试目标；任务 4 加入 `MangaPlatform`，任务 7 加入 `SourceProbe`，任务 14 加入 `MangaUI`。任何目标加入时都已有实际代码，不建立空壳目标。

| 目录 | 职责 |
| --- | --- |
| `Sources/MangaCore/Models/` | 身份、作品、章节、页面、进度和错误模型 |
| `Sources/MangaCore/Storage/` | SQLite 迁移、资料读写与事务 |
| `Sources/MangaCore/Networking/` | 请求上下文、调度、超时与重试 |
| `Sources/MangaCore/Sources/` | 解析协议、模板、站点适配、检测与绑定 |
| `Sources/MangaCore/Library/` | 搜索、作品关联和书架 |
| `Sources/MangaCore/Reading/` | 页序、续读与阅读状态 |
| `Sources/MangaCore/Downloads/` | 离线清单、任务状态与恢复 |
| `Sources/MangaCore/Updates/` | 更新基线、差分和提醒去重 |
| `Sources/MangaPlatform/` | WebKit、图像解码/缓存、通知和后台服务 |
| `Sources/MangaUI/` | 导航、列表、详情、阅读器、源管理与设置 |
| `Apps/iOS/`、`Apps/macOS/` | 两个平台的应用入口、权限与生命周期 |
| `Tests/` | Swift Testing 单元和组件测试，脱敏网页与生成图片样本 |
| `Apps/UITests/` | 两个平台的关键用户流程测试 |
| `Tools/SourceProbe/` | 人工触发的在线源验证命令行工具 |

依赖方向：`MangaPlatform → MangaCore`；`MangaUI → MangaCore + MangaPlatform`；应用和 SourceProbe 组合这些服务。Core 不导入 SwiftUI / WebKit / AppKit / UIKit。跨 actor 数据采用值类型和 `Sendable`，平台图像与 WebKit 操作保持明确的隔离边界。

实施时使用独立工作区，按 using-git-worktrees 技能选择现有或创建适合的工作树。文档现在写在主工作区；此计划审批前不创建产品代码、安装产品依赖或创建实现工作树。

Files 列表中省略目录的文件沿用最近一个明确路径的父目录；接口块中定义的附属类型放在同任务的对应模型或协议文件，不另建巨型通用文件。

## 验证约定与版本

2026-10-02 查询官方发布记录：GRDB `v7.11.1`、SwiftSoup `2.13.9`、XcodeGen `2.46.0`。已读取两个 Swift 包对应 release manifest：GRDB 需要 Swift 6.1，SwiftSoup 需要 Swift 6.0，系统版本要求均低于本项目下限；这只确认声明兼容性，未执行依赖构建。任务 1 使用精确版本并提交 `Package.resolved`；兼容性问题需要有构建证据，再调整版本。

所有任务的红绿循环只用于实现功能的必要行为。Swift Testing 测试使用临时目录和受控 HTTPClient，不依赖公网，不用真实等待模拟超时。每步只在检查通过后勾选；每个任务提交明确文件，禁止 `git add .` 混入其他工作。

当前机器有 Swift 6.2.4 / Command Line Tools，常规目录未发现完整 Xcode。先执行可运行的共享模块验证；完整 Xcode 下完成工程构建、模拟器、界面与安装验证。缺少环境时记录待执行检查，不能把任务 16、17 或整项目标标为完成。

## Task 1: 共享模型与稳定身份

**Files:** Create `Package.swift`, `.gitignore`, `Sources/MangaCore/Models/Identity.swift`, `CatalogModels.swift`, `ReadingModels.swift`, `SourceModels.swift`, `MangaError.swift`, `Sources/MangaCore/Networking/ResourceRequest.swift`, `Tests/MangaCoreTests/IdentityTests.swift`, `Tests/MangaCoreTests/TestSupport.swift`。未带目录的模型文件位于 `Sources/MangaCore/Models/`。

**Interfaces:** `SourceID` / `WorkID` 为 UUID 包装；`SourceWorkID(sourceID: SourceID, externalID: String)`、`ChapterID(sourceWorkID: SourceWorkID, externalID: String)`、`PageID(chapterID: ChapterID, externalID: String)`。模型定义 `Source`、`Work`、`SourceWork`、`Chapter`、`PageResource`、`ReadingProgress`、`ReaderPreferences`、`UserSettings`、`SourceCapabilities`、`ParserBinding`。页面有 `id`、`ordinal`、`request: ResourceRequest`；进度有章节、页面和 `fraction`。Source 保留 baseURL、revision、enabled 与绑定。SourceWork 保留原始标题、别名、作者、URL 和能力。UserSettings 在 ReadingModels.swift 定义，theme 默认为 system、通知 false、解码缓存 64 MiB、磁盘缓存 256 MiB。

- [x] **1. 写失败测试：** 先建立能发现测试的最小 manifest 与空 Core 源文件，然后写 `sameExternalIDOnDifferentSources()` 断言 `#expect(chapterA.id != chapterB.id)`；`differentBasePathsStayDistinct()` 断言 `/a/` 与 `/b/` 非重复源；`ephemeralURLDoesNotChangePageIdentity()` 断言签名变化后 PageID 不变。TestSupport 提供固定两源、作品、章节和两个页 ID，后续任务复用。
- [x] **2. 验证失败：** `swift test --filter IdentityTests`，应因目标类型/功能未定义而失败。
- [x] **3. 实现：** 身份按父级组合；`canonicalSourceURL(_ url: URL) throws -> URL` 移除 fragment 和默认端口，保留子路径及语义 query，拒绝非 HTTP(S)。同时定义任务 3 描述的 ResourceRequest / ResourceResponse，保证 PageResource 本步能编译。建立错误分类及可序列化模型，折叠包初始化和依赖锁定到本任务。
- [x] **4. 验证通过：** 同一命令应全部通过；`swift build` 应退出 0。
- [x] **5. 提交：** 仅提交本任务文件和锁文件，提交信息 `feat: define manga domain and stable identities`。

## Task 2: 本地数据库、关联与迁移

**Files:** Create `Sources/MangaCore/Storage/LibraryStore.swift`, `Schema.swift`, `Records.swift`, `Tests/MangaCoreTests/LibraryStoreTests.swift`。

**Interfaces:** `actor LibraryStore` 提供 `init(databaseURL: URL) throws`、`save(source: Source)`、`sources() -> [Source]`、`save(sourceWork: SourceWork, chapters: [Chapter])`、`createWork(from: SourceWorkID) -> Work`、`link(_: SourceWorkID, to: WorkID)`、`unlink(_: SourceWorkID, from: WorkID)`、`library() -> [Work]`、`sourceWorks(for: WorkID) -> [SourceWork]`、`chapters(for: SourceWorkID) -> [Chapter]`、`save(progress: ReadingProgress)`、`progress(for: SourceWorkID) -> ReadingProgress?`、`save(preferences: ReaderPreferences, for: WorkID)`、`preferences(for: WorkID) -> ReaderPreferences`、`save(settings: UserSettings)`、`settings() -> UserSettings`；各操作 async throws。下载和观察记录在所属任务添加。

- [x] **1. 写失败测试：** `reopenRetainsSourceScopedProgress()` 保存两源不同进度，重新打开 DB 后分别恢复；`mergeAndSplitRetainRecords()` 验证合并/解除关联不丢进度；`emptyResponseDoesNotEraseChapters()` 验证空响应保留旧目录；`migratesWithoutDataLoss()` 验证初版 schema 重开不重复迁移。
- [x] **2. 验证失败：** `swift test --filter LibraryStoreTests`，应因 store 或持久化行为缺失失败。
- [x] **3. 实现：** GRDB 串行访问，事务保存关系，唯一约束使用复合身份。新增 `save(binding: ParserBinding, sourceID: SourceID, expectedRevision: Int) -> Bool`，只有源版本匹配才提交。停用/删除源保留 SourceWork 和下载所需的来源快照，使用可恢复的失效状态。
- [x] **4. 验证通过：** 上述测试及 `swift test --filter IdentityTests` 全通过；增加 stale revision 的断言 `#expect(saved == false)`。
- [x] **5. 提交：** `feat: persist local library and source scoped progress`。

## Task 3: 请求上下文与有限网络调度

**Files:** Create `Sources/MangaCore/Networking/HTTPClient.swift`, `RequestScheduler.swift`, `AccessContextStore.swift`, `Tests/MangaCoreTests/HTTPClientTests.swift`；Modify `Sources/MangaCore/Networking/ResourceRequest.swift`。未带目录的网络文件位于 `Sources/MangaCore/Networking/`。

**Interfaces:** `ResourceRequest(url: URL, referer: URL?, headers: [String:String], accessContextID: UUID?)`；`ResourceResponse(data: Data, finalURL: URL, statusCode: Int, headers: [String:String])`；`HTTPClient.send(_ request: ResourceRequest, sourceID: SourceID, priority: RequestPriority) async throws -> ResourceResponse`。`RequestPriority` 顺序为 reading、probe、search、download、prefetch。`AccessContextStore` 以对应 SourceID 保存凭据，调用方不持有明文凭据。

- [x] **1. 写失败测试：** `limitedConcurrencyAndPriority()` 断言单源最多 2 / 全局最多 8；`retryAfterAndCancellation()` 验证 429 退避期间可取消，最多重试 2 次；`crossOriginRedirectDropsSecrets()` 断言 `#expect(redirected.authorization == nil)`；`sourceErrorsStayDistinct()` 验证 403、超时、网络离线的不同错误。
- [x] **2. 验证失败：** `swift test --filter HTTPClientTests`，应因调度和分类未实现失败。
- [x] **3. 实现：** URLSession 与可注入传输/时钟，普通请求超时 12 秒；退避最长 60 秒，尊重有效 Retry-After。凭据只适用于确认的源 origin；跨 origin 重定向不能自动携带敏感头。源可明确登记图片 CDN，Referer 与凭据允许范围分别处理。日志仅记录源、状态和脱敏路径。
- [x] **4. 验证通过：** 相同测试全部通过；取消请求不能留下持有并发额度的任务。
- [x] **5. 提交：** `feat: add scoped requests and bounded scheduling`。

## Task 4: 解析协议、通用模板与图片判定

**Files:** Create `Sources/MangaCore/Sources/SourceAdapter.swift`, `ParserRegistry.swift`, `HTMLTemplateAdapter.swift`, `JSONTemplateAdapter.swift`, `ImageVerifying.swift`, `PageRenderer.swift`, `Sources/MangaPlatform/Images/ImageVerifier.swift`, `Tests/MangaCoreTests/TemplateParserTests.swift`, `Tests/MangaPlatformTests/ImageVerifierTests.swift`, `Tests/MangaCoreTests/Fixtures/template-reader.html`, `template-catalog.json`；Modify `Package.swift`。未带目录的解析文件在 `Sources/MangaCore/Sources/`，样本在对应 Fixtures 目录。

**Interfaces:** `SourceAdapter` 有 `id: String`、`version: Int`、`capabilities: SourceCapabilities`；`browse(context: ParserContext) -> [SourceWork]`、`search(query: String, context: ParserContext) -> [SourceWork]`、`details(url: URL, context: ParserContext) -> SourceWork`、`chapters(work: SourceWork, context: ParserContext) -> [Chapter]`、`pages(chapter: Chapter, context: ParserContext) -> [PageResource]` 均 async throws。`ParserContext` 包含 Source、HTTPClient、可选 `PageRenderer`。在 Core 定义 `ImageVerifying.verify(_ data: Data) throws -> ImageMetadata` 及任务 6 的 PageRenderer / RenderedPage 协议；Platform 提供实际图片验证实现，Metadata 包含像素宽高和格式。

- [x] **1. 写失败测试：** `readerImagesExcludeAdsAndCovers()` 断言只返回正文且页序正确；`followsChapterPaginationWithoutLoops()` 验证分页去重与循环终止；`jsonTemplateRequiresKnownSchema()` 验证支持的字段映射和未知结构拒绝；`htmlIsNotAnImage()` 断言 HTTP 200 的 HTML 无法通过图片验证；`truncatedImageRejected()` 验证破损图不可用。
- [x] **2. 验证失败：** `swift test --filter 'TemplateParserTests|ImageVerifierTests'` 应失败。
- [x] **3. 实现：** SwiftSoup 提取明确阅读区域内 src / data-src / data-original，排除占位及广告；JSON 模板使用固定声明字段映射，首个模板为作品/章节目录及 `pages: [{id, ordinal, url}]`。注册表稳定优先级、版本和特征。ImageIO 验证实际可解码图，PNG/JPEG/WebP 逐个检测平台支持；不支持时显式失败。样本图片自行生成，网页样本只保留最小脱敏结构。
- [x] **4. 验证通过：** 同一命令全通过，完整与损坏样本均符合预期；记录平台实际支持格式。
- [x] **5. 提交：** `feat: parse supported templates and validate comic images`。

## Task 5: 自定义源探测、自动绑定与失效恢复

**Files:** Create `Sources/MangaCore/Sources/SourceDetector.swift`, `SourceService.swift`, `DetectionReport.swift`, `Tests/MangaCoreTests/SourceDetectorTests.swift`。

**Interfaces:** `SourceDetector.detect(source: Source, samples: [URL]) async -> DetectionReport`；报告区分 verified、limited、ambiguous、needsSamples、accessFailure、unsupported。`SourceService.add(name: String, baseURL: URL, samples: [URL]) async throws -> DetectionReport`、`retest(sourceID: SourceID, samples: [URL]) async throws -> DetectionReport`、`adapter(for: SourceID) async throws -> any SourceAdapter`、`context(for: SourceID) async throws -> ParserContext`、`setEnabled(_: Bool, sourceID: SourceID) async throws`、`remove(sourceID: SourceID) async throws`。绑定存入任务 2 store；探测验证调用任务 4 ImageVerifying。

- [x] **1. 写失败测试：** `verifiedBindingIsReused()` 断言第二次读取不全量探测；`ambiguousContentRequiresChoice()` 验证正文不一致不自动绑定；`accessFailureIsNotUnsupported()` 验证 403 分类；`cancelledDetectionCannotOverwriteNewBinding()` 验证旧检测结束不写入；`limitedSamplesAreLabelled()` 验证单作品绑定标明有限验证。
- [x] **2. 验证失败：** `swift test --filter SourceDetectorTests` 应失败。
- [x] **3. 实现：** 同一次检测复用页面，最多 30 次网络请求 / 60 秒，自动发现样本限同源公开链接；用户样本允许确认后的正常重定向。目标两作品各两章，每章验证有序列表及代表性正文解码。候选正文完全一致按优先级选择；差异用稳定页面身份与资源路径判断，临时签名差异不单独制造歧义。版本/URL revision 轻量验证，连续 2 次结构不匹配标记需重新检测；网络或单图错误不清除绑定。
- [x] **4. 验证通过：** 相同测试全通过；补充取消时数据库无半成品、编辑 URL 后旧绑定不沿用的断言。
- [x] **5. 提交：** `feat: detect custom sources and reuse verified bindings`。

## Task 6: WebKit 源访问与渲染上下文

**Files:** Create `Sources/MangaPlatform/Web/WebKitRenderer.swift`, `Sources/MangaPlatform/Web/WebAccessSession.swift`, `Tests/MangaPlatformTests/WebAccessPolicyTests.swift`；Modify `Sources/MangaCore/Sources/PageRenderer.swift`。

**Interfaces:** `PageRenderer.render(url: URL, source: Source, interactive: Bool) async throws -> RenderedPage`；RenderedPage 提供 HTML、最终 URL 和局部 accessContextID。`@MainActor WebAccessSession` 持有受控 WKWebView 和可呈现的源页面，正常登录/验证后刷新任务 3 对应源上下文。

- [x] **1. 写失败测试：** `sourceContextsRemainSeparate()` 验证两个源 Cookie 不混用；`unrelatedNavigationDoesNotCreateBinding()` 验证无关跳转不能改变源身份；`renderTimeoutAndCancellation()` 验证导航取消清理 continuation；`credentialsAreNotLogged()` 验证诊断日志脱敏。
- [x] **2. 验证失败：** `swift test --filter WebAccessPolicyTests` 应失败。
- [x] **3. 实现：** WebKit 生命周期由 MainActor 管理，页面按源隔离；读取 DOM 的脚本内置且仅用于对应适配，不引入用户或远程可执行插件。访问受限时提供可交互源页面，不自动绕过验证、付费或权限。无头纯 HTTP 路径仍优先。
- [ ] **4. 验证通过：** policy 测试通过；完整 Xcode 可用后用本地测试页面实际验证 DOM、取消和可见验证入口。此人工平台检查单独记录。
- [x] **5. 提交：** `feat: support controlled source page rendering`。

## Task 7: 瓜子漫画适配与在线验证工具

**Files:** Create `Sources/MangaCore/Sources/Adapters/GuaziAdapter.swift`, `BuiltinSources.swift`, `Tools/SourceProbe/main.swift`, `Tests/MangaCoreTests/GuaziAdapterTests.swift`, `Tests/MangaCoreTests/Fixtures/guazi-detail.html`, `guazi-chapter.html`, `docs/source-validation.md`；Modify `Package.swift`。

**Interfaces:** GuaziAdapter 实现任务 4 SourceAdapter，id=`guazi-html`。`BuiltinSources.candidates() -> [Source]` 输出三站候选且未验证能力不标可用。SourceProbe 参数 `--source guazi --work-url <URL> --online`，输出各能力和首图解码结果；不打印 Cookie 或签名。

- [x] **1. 写失败测试：** `guaziDirectoryAndPages()` 验证 comic.php / chapter.php 的语义 ID、目录顺序及 `.reading-image`；`guaziCDNRestrictionReported()` 断言正文 403 保留 accessFailure；`browseAndSearchCapabilitiesAreIndependent()` 验证仅确认后启用搜索与浏览。
- [x] **2. 验证失败：** `swift test --filter GuaziAdapterTests` 应失败。
- [x] **3. 实现：** 首先重新读取站点正常浏览流程确认搜索/浏览入口；复用真实页面提供的目录和图片链接。通过任务 3、6 验证普通浏览上下文能否读取 CDN；仍失败则保存证据和受限状态，不能宣称阅读适配完成。
- [ ] **4. 验证：** fixture 测试全通过；执行 `swift run SourceProbe --source guazi --work-url 'https://www.guazimanhua.com/comic.php?id=26470' --online`，报告必须包含实际首页/详情/章节/图片状态。只有首图解码和章节页序成功才通过在线阅读验收。
- [x] **5. 提交：** `feat: add guazi adapter and explicit source diagnostics`；source-validation 保留实际日期、环境和失败原因。

## Task 8: DM5 动态阅读适配

**Files:** Create `Sources/MangaCore/Sources/Adapters/DM5Adapter.swift`, `Tests/MangaCoreTests/DM5AdapterTests.swift`, `Tests/MangaCoreTests/Fixtures/dm5-detail.html`, `dm5-reader.html`；Modify `BuiltinSources.swift`, `Tools/SourceProbe/main.swift`, `docs/source-validation.md`。

**Interfaces:** DM5Adapter 实现 SourceAdapter，id=`dm5-reader`，由网站正常公开阅读流程获取动态请求上下文；PageResource 保留稳定页号，不把临时签名当 ID。

- [x] **1. 写失败测试：** `dm5PageOrderAndCount()` 验证分页完整且有序；`expiredContextRefreshesWithoutChangingIdentity()` 验证上下文刷新而 PageID 不变；`paidChapterStaysUnavailable()` 验证付费页不会被解析为正文。
- [x] **2. 验证失败：** `swift test --filter DM5AdapterTests` 应失败。
- [x] **3. 实现：** 根据实际公开 reader 脚本确认章节接口；获取网站生成的时效参数或通过 WebKit 正常加载正文。解析响应采用已确认格式，不执行不受控接口文本。付费/登录/访问错误明确分类，能力分别登记。
- [ ] **4. 验证：** 测试通过；`swift run SourceProbe --source dm5 --work-url 'https://www.dm5.com/manhua-yirenzhixia/' --online`，至少验证可访问章节首页、末页及过期刷新；正文仍无法取得时在线验收保持未完成。
- [x] **5. 提交：** `feat: adapt dm5 dynamic reading requests`，同时记录验证结果。

## Task 9: 漫画站适配

**Files:** Create `Sources/MangaCore/Sources/Adapters/ManhuazhanAdapter.swift`, `Tests/MangaCoreTests/ManhuazhanAdapterTests.swift`, `Tests/MangaCoreTests/Fixtures/manhuazhan-detail.html`；Modify `BuiltinSources.swift`, `Tools/SourceProbe/main.swift`, `docs/source-validation.md`。

**Interfaces:** ManhuazhanAdapter 实现 SourceAdapter，id=`manhuazhan-reader`。页面模板和正文方式以实际能读取的页面确认，不预设与瓜子/DM5相同。

- [x] **1. 写失败测试：** `manhuazhanLinksPreserveSemanticIDs()` 验证目录身份与相对 URL；`challengePageDoesNotLookLikeComic()` 验证访问限制不误匹配；正文可取得后加入 `manhuazhanCompletePageList()` 验证末页和正文区域。
- [x] **2. 验证失败：** `swift test --filter ManhuazhanAdapterTests` 应失败。
- [x] **3. 实现：** 先验证正常 HTTP 和可见 WebKit 浏览路径，读取实际详情/正文格式再适配。仍为 403 时实现明确的受限反馈、记录未解决项并继续独立功能；不能用网页搜索缓存证明原站可读。
- [x] **4. 验证：** 样本测试通过；`swift run SourceProbe --source manhuazhan --work-url 'https://www.manhuazhan.com/comic/219424' --online`。无法解码真实正文时该源阅读目标保持未完成。
- [x] **5. 提交：** `feat: add manhuazhan adapter and access status`。

## Task 10: 跨源搜索、作品关联与续读候选

**Files:** Create `Sources/MangaCore/Library/SearchService.swift`, `AssociationService.swift`, `Sources/MangaCore/Reading/ResumeMatcher.swift`, `Tests/MangaCoreTests/SearchServiceTests.swift`, `AssociationTests.swift`, `ResumeMatcherTests.swift`。

**Interfaces:** `SearchService.search(query: String, sourceIDs: [SourceID], queryID: UUID) -> AsyncStream<SearchEvent>`；事件 results、failure、finished 均包含 queryID，results 保留 SourceID。`AssociationService.candidates(for: SourceWork, among: [SourceWork]) -> [AssociationCandidate]`；`confirmLink(_: SourceWorkID, to: WorkID) async throws` 调用 store。`ResumeMatcher.candidates(progress: ReadingProgress, from: [Chapter], to: [Chapter]) -> [ChapterID]` 只提供候选。

- [x] **1. 写失败测试：** `fastSourceReturnsBeforeSlowFailure()` 验证部分结果可用；`oldQueryCannotReplaceNewResults()` 验证取消后无旧响应覆盖；`sameTitleIsNotAutomaticallyMerged()` 断言确认前两 Work 分开；`seasonAndEditionRemainDistinct()` 验证第 1/2 季及版本差异不误关联；`splitChapterRequiresSelection()` 验证拆章只能给候选。
- [x] **2. 验证失败：** `swift test --filter 'SearchServiceTests|AssociationTests|ResumeMatcherTests'` 应失败。
- [x] **3. 实现：** 限可用搜索能力，多源并发事件；标题做 Unicode / 空白规范化，保留季数和版次，结合别名/作者给候选。用户明确确认才执行事务关联，解除关联不删除旧进度。章节编号和标题共同匹配，不仅按数组下标。
- [x] **4. 验证通过：** 同一命令全通过；慢源失败和歧义不会改变已有库资料。
- [x] **5. 提交：** `feat: search across sources and confirm work associations`。

## Task 11: 图片加载、长图与独立缓存

**Files:** Create `Sources/MangaPlatform/Images/PageFileStore.swift`, `ImagePipeline.swift`, `TiledImageDecoder.swift`, `Tests/MangaPlatformTests/ImagePipelineTests.swift`。

**Interfaces:** `PageFileStore.cachedFile(for: PageID) async -> URL?`、`writeCache(data: Data, pageID: PageID) async throws -> URL`、`clearCache() async throws`；离线文件目录由任务 12 单独管理。`ImagePipeline.file(for: PageResource, sourceID: SourceID) async throws -> URL`、`prefetch(_: [PageResource], sourceID: SourceID)`、`cancelPrefetch(chapterID: ChapterID)`。`TiledImageDecoder.decode(file: URL, viewport: PixelRect, targetWidth: Int) throws -> [ImageTile]`。

- [x] **1. 写失败测试：** `readingPreemptsPrefetch()` 验证当前页优先；`cancelPrefetchReleasesResources()` 验证换章取消；`longImageHasBoundedTiles()` 验证 20000 像素长图按不超过 4096 像素高的区块读取；`sameSignedPageSharesCacheKey()` 验证 URL 更新复用身份；`invalidDataNeverCachedAsReadable()` 验证错误内容被拒绝。
- [x] **2. 验证失败：** `swift test --filter ImagePipelineTests` 应失败。
- [x] **3. 实现：** 文件原子写入并验证，解码在非主线程；内存解码缓存默认上限 64 MiB、磁盘自动缓存 256 MiB，初始预取后 3 页，内存压力时缩小窗口。只加载可视区和附近区块，禁止通过完整解码原长图再裁切来假装节省内存。无法区域解码的格式使用受限缩采样并报告实际内存。
- [x] **4. 验证通过：** 相同测试全通过；补充内存压力和离开章节的释放检查，实机峰值在任务 17 测量。
- [x] **5. 提交：** `feat: prioritize comic images and bound decoding memory`。

## Task 12: 离线下载、恢复与断网阅读

**Files:** Create `Sources/MangaCore/Downloads/DownloadModels.swift`, `DownloadManager.swift`, `OfflineManifest.swift`, `Sources/MangaPlatform/Background/BackgroundTransfer.swift`, `Tests/MangaCoreTests/DownloadManagerTests.swift`；Modify `LibraryStore.swift`, `Schema.swift`。

**Interfaces:** `DownloadManager.enqueue(chapter: Chapter, pages: [PageResource]) async throws -> UUID`、`pause(taskID: UUID)`、`resume(taskID: UUID)`、`cancel(taskID: UUID)`、`retry(taskID: UUID)`、`deleteDownloaded(chapterID: ChapterID)`、`restore() async throws`、`offlinePages(chapterID: ChapterID) async throws -> [URL]`；操作均 async throws。`DownloadTask` / `OfflineManifest` 保存稳定页身份、有序文件、校验摘要、状态和来源快照。Core 的 DownloadModels 定义 `PageTransferring.download(_: ResourceRequest, sourceID: SourceID, taskID: UUID, to: URL) async throws -> TransferResult` 与 `recoverTransfers() async throws -> [TransferRecord]`，结果保存状态码、文件位置及字节数，记录保存 taskID 和传输状态；Platform 实现后台传输。新增 store 的 download/manifest 事务接口。

- [x] **1. 写失败测试：** `restartWithNewSignatureKeepsCompletedPages()` 验证重启刷新 URL 后仅补缺页；`missingOrCorruptPageIsNotComplete()` 断言 `#expect(task.state != .completed)`；`clearCachePreservesOfflineChapter()` 验证缓存清理后断网读取完整；`diskFullPausesWithoutDeletingDownloads()` 验证磁盘不足状态；`removedSourceStillReadsOffline()` 验证源删除后离线可读。
- [x] **2. 验证失败：** `swift test --filter DownloadManagerTests` 应失败。
- [x] **3. 实现：** 状态 queued/running/paused/failed/completed/cancelled，逐页校验后提交文件和 DB；恢复时验证文件摘要和 manifest，再从源刷新临时资源。支持 Range 才按字节续传，否则按页恢复。后台 URLSession completion 通过稳定 taskID 映射，系统中断后重开核对实际任务；运行中停用源暂停其任务。取消完成文件可移为缓存，删除离线内容只删对应 manifest 文件。
- [ ] **4. 验证通过：** 核心测试全通过；完整 Xcode 下验证后台传输恢复和断网阅读，不承诺强制退出后继续运行。
- [x] **5. 提交：** `feat: download and restore verified offline chapters`。

## Task 13: 更新基线、通知和后台检查

**Files:** Create `Sources/MangaCore/Updates/UpdateService.swift`, `UpdateModels.swift`, `Sources/MangaPlatform/Notifications/NotificationService.swift`, `Sources/MangaPlatform/Background/UpdateScheduler.swift`, `Tests/MangaCoreTests/UpdateServiceTests.swift`；Modify `LibraryStore.swift`, `Schema.swift`。

**Interfaces:** `UpdateService.check(sourceWorkIDs: [SourceWorkID]) async -> [UpdateResult]`、`setFollowed(_: Bool, sourceWorkID: SourceWorkID) async throws`；store 保存 UpdateObservation、已通知批次。在 Core 的 UpdateModels 定义 `NotificationDelivering.notify(workID: WorkID, chapters: [Chapter]) async throws`，Platform 实现；`UpdateScheduler.onAppActive()`、`scheduleNext()` 在 MainActor 调用，平台实现按系统机制运行。

- [x] **1. 写失败测试：** `firstCheckCreatesBaseline()` 断言首次新增数为 0；`newChaptersNotifyOnce()` 验证重试无重复通知；`emptyResponsePreservesBaseline()` 验证空目录不删除基线；`permissionDeniedStillUpdatesList()` 验证提醒失败不丢更新；`unfollowedSourceIsNotChecked()` 验证关注范围。
- [x] **2. 验证失败：** `swift test --filter UpdateServiceTests` 应失败。
- [x] **3. 实现：** 差分使用稳定章节 ID；加入书架关注当前源，多源独立检查。通知默认关闭、按作品和检查批次合并。iOS 注册 BGAppRefreshTask 并处理过期取消；macOS 仅应用运行时检查，默认 30 分钟且可手动刷新；重新激活避免重叠检查。不安装常驻服务。
- [ ] **4. 验证通过：** 测试全通过；平台权限拒绝/允许与后台过期在任务 17 验证。
- [x] **5. 提交：** `feat: track new chapters and deliver local update reminders`。

## Task 14: 双平台导航、资料页面和源管理

**Files:** Create `Sources/MangaCore/Library/NavigationState.swift`, `Sources/MangaUI/App/AppContainer.swift`, `RootNavigation.swift`, `Sources/MangaUI/Library/LibraryView.swift`, `WorkDetailView.swift`, `ChapterListView.swift`, `Sources/MangaUI/Discovery/DiscoveryView.swift`, `Sources/MangaUI/Sources/SourceManagementView.swift`, `DetectionResultView.swift`, `Sources/MangaUI/Downloads/DownloadsView.swift`, `Sources/MangaUI/Updates/UpdatesView.swift`, `Sources/MangaUI/Settings/SettingsView.swift`, `Tests/MangaCoreTests/NavigationStateTests.swift`；Modify `Package.swift`。UI 文件的省略目录沿用前一个明确路径。

**Interfaces:** `AppContainer` 注入任务 2–13 服务和 Core 的 UserSettings（theme、通知、缓存设置）。Core 的 NavigationState 定义 `Route`：work(WorkID)、chapters(SourceWorkID)、reader(ChapterID)；`NavigationState.open(workID: WorkID) async throws -> Route` 恢复来源可用时的阅读位置，否则进入作品详情。`RootNavigation<ReaderContent: View>` 接收 `readerDestination: (ChapterID) -> ReaderContent`，本步不依赖任务 15 尚未实现的 ReaderView。SwiftUI 由 MainActor 可观察模型消费服务。

- [x] **1. 写失败测试：** `libraryResumesSelectedSource()` 验证点击书架正确恢复；`unavailableSourceShowsAlternatives()` 验证失效来源进入详情而非自动换源；`selectingSourceRoutesToItsChapters()` 验证选源后的章节身份。
- [x] **2. 验证失败：** `swift test --filter NavigationStateTests` 应失败。
- [x] **3. 实现：** iOS 四个底部入口、macOS 对应侧栏；搜索流式结果、关联候选确认/拆分、来源卡片和关注调整、下载操作、更新列表、源管理。自定义源支持有限验证/歧义预览/补充样本/可见源页面等状态。提供空态、失败态和加载态；遵循系统字体、明暗主题、可访问标签和 iPad 自适应。Source 停用与删除按设计保留资料。
- [x] **4. 验证通过：** 导航测试和 `swift build --target MangaUI` 通过；实际界面测试在任务 16、17 完成。
- [x] **5. 提交：** `feat: build native library discovery and source management screens`。

## Task 15: 阅读状态、滚动/翻页与 macOS 双页

**Files:** Create `Sources/MangaCore/Reading/ReadingSession.swift`, `PageLayout.swift`, `Sources/MangaUI/Reader/ReaderView.swift`, `ScrollingReader.swift`, `PagedReader.swift`, `ZoomablePage.swift`, `ReaderToolbar.swift`, `Tests/MangaCoreTests/ReadingSessionTests.swift`, `PageLayoutTests.swift`。

**Interfaces:** `ReadingSession.open(chapter: Chapter, preferences: ReaderPreferences) async throws -> ReaderState` 优先离线清单，否则 adapter；`recordPosition(pageID: PageID, fraction: Double)`、`changeMode(_:)`、`changeDirection(_:)`、`close()` 均 async throws。`PageLayout.spreads(pageIDs: [PageID], direction: ReadingDirection) -> [[PageID]]`。ReaderState 保留当前源、章节、页序、位置和失败页。

- [ ] **1. 写失败测试：** `readerModeSwitchRetainsPage()` 验证模式切换当前页不变；`firstAndOddLastPagesStandAlone()` 验证首页单页、奇数末页和 RTL 排列；`scrollFractionRoundTrips()` 验证页内位置；`failedPageKeepsPlaceholder()` 验证错误页保留页序；`sourceSwitchDoesNotOverwriteOldProgress()` 验证跨源需用户确认候选。
- [ ] **2. 验证失败：** `swift test --filter 'ReadingSessionTests|PageLayoutTests'` 应失败。
- [ ] **3. 实现：** 滚动懒加载与分页容器使用任务 11 文件/图块，iOS UIKit 与 macOS AppKit 缩放桥接保持手势正确；支持目录、工具栏、页码、章节切换、背景和 macOS 键盘操作。保存节流并在退出刷写；换章取消旧加载，旧异步进度不得覆盖新章。偏好按 Work 保存，进度按 SourceWork 保存。
- [ ] **4. 验证通过：** 状态测试通过、MangaUI 构建通过；平台触控/鼠标缩放、长图、双页与位置恢复在任务 17 实际验收。
- [ ] **5. 提交：** `feat: read comics with scroll paging and desktop spreads`。

## Task 16: 可重复生成的双平台工程与应用生命周期

**Files:** Create `project.yml`, `Apps/iOS/MangaIOSApp.swift`, `Apps/iOS/AppDelegate.swift`, `Apps/iOS/Info.plist`, `Apps/macOS/MangaMacApp.swift`, `Apps/macOS/MangaMac.entitlements`, `Apps/macOS/Info.plist`, `scripts/generate-project.sh`, `scripts/check-environment.sh`, `ChasingManga.xcodeproj/project.pbxproj`, `ChasingManga.xcodeproj/xcshareddata/xcschemes/MangaIOS.xcscheme`, `MangaMac.xcscheme`。

**Interfaces:** 两入口初始化 AppContainer，首次启动只登记候选源，不自动声称全源可读；启动/激活/退出调用对应服务。iOS AppDelegate 接收后台传输 completion；后台刷新 ID 为 `com.chasingmanga.local.refresh`，后台 URLSession ID 为 `com.chasingmanga.local.download`。Bundle ID 分别 `com.chasingmanga.local.ios`、`com.chasingmanga.local.mac`；开发签名 Team 由用户本机设置，不提交私有账户值。

- [ ] **1. 写验证脚本：** check-environment 检测完整 Xcode、Swift 和 XcodeGen；缺少 Xcode 时退出非 0 并报告具体路径，不安装 Xcode 或修改系统选择。generate-project 固定 XcodeGen 2.46.0，生成包含两个共享 scheme 的工程。
- [ ] **2. 验证缺失环境：** 当前机器运行脚本预期报告缺少完整 Xcode；这不是构建成功证据。
- [ ] **3. 实现：** 配置本地 SwiftPM 包、iOS 17 / macOS 14、必要网络权限与后台标识；Mac 启用 App Sandbox 网络客户端权限。工程不包含模拟内容替代线上功能，不包含同步能力。生成工程和 schemes 提交，普通使用者不需 XcodeGen 即可打开工程。
- [ ] **4. 验证构建：** 完整 Xcode 下运行 `xcodebuild -project ChasingManga.xcodeproj -scheme MangaMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` 和 `xcodebuild -project ChasingManga.xcodeproj -scheme MangaIOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`，两者均 BUILD SUCCEEDED 才勾选。
- [ ] **5. 提交：** `build: provide native macOS and iOS app projects`；安装运行仍需任务 17 验证。

## Task 17: 用户流程、性能验证与开源使用文档

**Files:** Create `Apps/UITests/MangaFlowTests.swift`, `Tests/MangaCoreTests/EndToEndFlowTests.swift`, `docs/verification.md`, `docs/build-and-install.md`, `CONTRIBUTING.md`, `THIRD_PARTY_NOTICES.md`, `LICENSE`, `.github/workflows/verify.yml`；Modify `README.md`, `project.yml`。

**Interfaces:** UI 测试通过启动参数注入本地最小样本源和生成图片，生产默认入口不注册测试源。EndToEndFlowTests 串起实际服务：搜索→选源→书架→阅读→下载→更新→重开；online probe 另外执行，不用本地流程冒充在线验证。

- [ ] **1. 写失败测试：** `chooseSourceReadAndResume()` 验证两端来源卡片到阅读位置；`offlineChapterAfterRestart()` 验证重开断网可读；`customSourceBindThenRead()` 验证自定义绑定复用；`updateAndDeniedNotification()` 验证更新列表仍可用。交互测试覆盖滚动/翻页、RTL、Mac 双页和缩放；不用逐个 SwiftUI 视图写重复测试。
- [ ] **2. 验证失败：** `swift test --filter EndToEndFlowTests` 在未完成串接时应失败；Xcode 下 UI 测试在未接入入口时应失败。修复真实缺口，不改测试绕开产品行为。
- [ ] **3. 完成集成与文档：** 写清源能力、已知限制、完整 Xcode 与签名安装步骤；MIT 仅覆盖代码，第三方依赖列许可证。贡献文档说明内置解析协议、样本脱敏、HTTP 200 错误页和在线验证要求。加入 UI 测试 target 后重新生成并提交任务 16 的工程及 schemes。CI 使用 macOS runner 检查共享测试和双平台编译；配置提交不等于 CI 已在线运行。首版不自动发布、推送仓库或上架。
- [ ] **4. 最终验证：** `swift test`、任务 16 两条 build 命令、`xcodebuild -project ChasingManga.xcodeproj -scheme MangaMac -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO`、iOS 实际可用模拟器 UDID 的同等 test 命令及三源在线 probe。运行前由 `xcodebuild -showdestinations` 获取 UDID，不写虚构设备。实际启动两端，断网、通知拒绝、下载中断、重开与长图峰值逐项记录。测量首图时间、翻页等待及内存，记录设备/网络；无完整 Xcode 时这些检查保留未完成。`git diff --check` 无输出且退出 0。
- [ ] **5. 提交：** `docs: verify manga workflows and document local installation`。最终报告分别列通过、未通过和环境未执行项；仍有指定源阅读问题或双平台未验证时不能称完整首版已经交付。

## 设计覆盖自审

| 设计范围 | 实现任务 |
| --- | --- |
| 本地模式、稳定身份、保存重开、资料迁移 | 1、2、16 |
| 内置源、自定义探测、版本绑定、误判与访问错误 | 3–9 |
| 搜索、浏览、来源卡片、合并拆分与用户选择 | 4、7–10、14 |
| 滚动/翻页/RTL、双页、缩放与续读 | 11、15、17 |
| 缓存、离线完整性、下载操作、恢复与后台 | 11、12、16、17 |
| 更新、关注源、通知去重与权限 | 13、14、16、17 |
| 导航、源编辑/停用/删除、主题与空错态 | 5、14、16 |
| 首批源真实验证、性能、双平台编译安装与开源文档 | 7–9、16、17 |

本计划的实现阶段推荐由主代理顺序执行：服务接口联系紧密，先保持共享核心的一致性，再做整体独立审阅。执行方式由用户审阅本计划时选择。用户未批准计划并选择执行方式前，不开始实施。

## 官方依赖参考

- [GRDB](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)
- [SwiftSoup](https://github.com/scinfu/SwiftSoup/releases/tag/2.13.9)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)
