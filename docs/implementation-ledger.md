# SDD ledger — plan: docs/superpowers/plans/2026-10-02-manga-reader-implementation.md

Baseline: 613a295; managed isolated worktree, detached HEAD; repository has only README and approved documents, no baseline test runner.
Pre-flight: Task [1] -> 2: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [1] -> 3: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [1, 3] -> 4: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [2, 3, 4] -> 5: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [3, 4] -> 6: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [4, 5, 6] -> 7: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [4, 6, 7] -> 8: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [4, 6, 7] -> 9: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [2, 5, 7, 8, 9] -> 10: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [3, 4] -> 11: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [2, 5, 11] -> 12: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [2, 5] -> 13: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [2, 5, 10, 12, 13] -> 14: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [2, 10, 11, 12, 14] -> 15: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [6, 12, 13, 14, 15] -> 16: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Pre-flight: Task [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16] -> 17: consumed IDs / store / adapter / platform service match producer definitions; protocol types stay in Core.
Ruling: A managed detached worktree is used as returned by the native tool; preserve commits and defer branch integration to finish — avoids changing main — cost if wrong: branch creation at integration.

- [x] Task 1
- [x] Task 2
- [x] Task 3
- [ ] Task 4
- [ ] Task 5
- [ ] Task 6
- [ ] Task 7
- [ ] Task 8
- [ ] Task 9
- [ ] Task 10
- [ ] Task 11
- [ ] Task 12
- [ ] Task 13
- [ ] Task 14
- [ ] Task 15
- [ ] Task 16
- [ ] Task 17

Task 1: in progress
Task 1: Ruling: defer GRDB / SwiftSoup resolution to owning database / parser tasks — model tests do not consume them and full GRDB history fetch stalled — cost if wrong: later dependency initialization; pinned versions unchanged. Initial test attempt stopped before tests; not counted as RED.
Task 1: Ruling: CLT lacks both Testing and XCTest (imports independently reproduced). Shared behavior checks run via swift run MangaChecks and native Swift Testing facades — permits RED/GREEN without hiding missing Xcode — cost if wrong: native runtime checks remain explicitly pending.
Task 1: complete (commits 613a295..7404baf, tests: swift run MangaChecks → 4/4 checks passed)
Task 2: Ruling: use system SQLite3 rather than GRDB — SQLite3 3.43.2 successfully imports in this SDK; avoids stalled full-history dependency resolution and satisfies approved SQLite architecture — cost if wrong: maintain small parameterized SQL / migration wrapper, covered by persistence tests.
Task 2: complete (commits 7404baf..d92d54b, tests: swift run MangaChecks → 9/9 checks passed)
Task 3: complete (commits d92d54b..6013fec, tests: swift run MangaChecks → 16/16 checks passed)
Task 4: complete (commits 6013fec..9df8745, tests: swift run MangaChecks → 21/21 checks passed)
Task 5: complete (commits 9df8745..ba86a46, tests: swift run MangaChecks → 29/29 checks passed)

Task 6: Ruling: use Task 6 render(url:source:interactive:) signature over Task 4 request/sourceID signature — WebKit needs the full source and interactive intent; there were no existing implementations or call sites — cost if wrong: adapters must use the full-source API.
Task 6: WebKit DOM and visible verification interaction remain pending full Xcode; policy/lifecycle checks run through the portable runner.
Task 6: complete (commits ba86a46..62bcd1e, tests: swift run MangaChecks → 33/33 checks passed)
Task 7: complete (commits 62bcd1e..4417673, tests: swift run MangaChecks → 37/37 checks passed)

Task 8: Online original sample is region restricted; independent publicly accessible DM5 sample passed first/last chapter and image decoding. Real expiry and iOS checks remain pending; fixture signature refresh is not claimed as real expiry.
Task 8: complete (commits 4417673..425dfaf, tests: swift run MangaChecks → 43/43 checks passed)

Task 9: Ruling: extend ResourceRequest with optional POST method/body for the observed Manhuazhan search form — GET-only networking cannot follow its normal public search — cost if wrong: maintain redirect body isolation and Codable compatibility.
Task 9: Ruling: renderer metadata supplies Manhuazhan browser-generated newImgs list through a fixed read-only expression — normal site script owns encrypted DATA; avoids executing downloaded interface text in the app parser — cost if wrong: first load depends on WebKit and can be slower than pure HTTP.

Task 9: Native macOS WebKit online probe passed real complete first/last chapter lists and representative images. Search returned zero results for the first query; capability validation remains independent.
Task 9: complete (commits 425dfaf..cde3b8d, tests: swift run MangaChecks → 47/47 checks passed)

Task 10: Ruling: built-in source IDs use the compiled adapter mapping before custom-source binding; catalog capabilities remain empty until live inspection succeeds — allows browsing/reading known sources without an unnecessary full automatic probe — cost if wrong: each capability must remain independently validated, including challenged Manhuazhan search.
Task 10: complete (commits cde3b8d..3e510a2, tests: swift run MangaChecks → 53/53 checks passed)
Task 11: complete (commits 3e510a2..1c6d854, tests: swift run MangaChecks → 59/59 checks passed)

Task 12: Ruling: download/update records extend the existing generic records table without changing SQL schema version — no new SQL columns or indexes are required — cost if wrong: future JSON record migrations must remain explicit and tested.

Task 12: Native background transfer compiles in macOS platform target; actual suspension/relaunch and iOS background completion remain pending full Xcode. Core integrity/restart/offline checks passed.
Task 12: complete (commits 1c6d854..1cc5805, tests: swift run MangaChecks → 64/64 checks passed)

Task 13: Ruling: credentialed downloads use the foreground transport with redirect control — Apple SDK NSURLSession.h explicitly states background redirects always follow and do not invoke the redirect delegate — cost if wrong: credentialed downloads may pause when the app is suspended; uncredentialed CDN downloads keep native background transfer.
Task 13: Ruling: persist update notification attempt before dispatch — prevents duplicates after process interruption and retains update records on permission failure — cost if wrong: a crash between persistence and notification may lose one reminder, while the update list remains available.
Task 13: complete (commits 1cc5805..427658e, tests: swift run MangaChecks → 69/69 checks passed)

Task 14: Ruling: add backward-compatible optional isOnShelf to Work — opening search results must not silently add them to the shelf; existing records with no flag remain on shelf — cost if wrong: new shelf filtering and explicit add/remove behavior, covered in integration checks.
Task 14: complete (commits 427658e..eecebfd, tests: swift run MangaChecks → 73/73 checks passed)

Task 15: Ruling: odd last means an unpaired page after the standalone cover — standard spreads pair the remaining sequence, so six total pages yield a standalone last page; five total pages end in a pair — cost if wrong: users expecting an odd total page count to always end alone see standard cover-first pairing instead.
Task 15: complete (commits eecebfd..1be6305, tests: swift run MangaChecks → 78/78 checks passed)
Task 16: complete (commits 1be6305..18b5ee4, tests: swift run MangaChecks → 78/78 checks passed)

Task 16: XcodeGen 2.46.0 official release hash verified and project generated; Mac app entry typechecked. Both xcodebuild commands failed at environment selection (CLT only), so plan build checkbox remains pending.
Task 17: Ruling: native test target explicitly errors when Swift Testing is unavailable — conditional facades previously allowed swift test to exit 0 without executing checks on CLT — cost if wrong: CLT users must use the portable runner; full Xcode executes the same checks natively.
Task 17: Real Mac UI preview launched via CLT-linked native .app; List chapter click failed then passed after borderless/contentShape fix. Manual paging and double-page mode verified. Full Xcode/iOS/gesture/background/performance acceptance remains pending and documented. Three final online probes passed reading; Manhuazhan search now HTTP 500.
Task 17: complete (commits 18b5ee4..de96208, tests: swift run MangaChecks → 82/82 checks passed)

Final review: fresh independent gpt-6-astra reviewer, range 613a295..de96208; 9 Important, 0 Critical, 0 Minor. All 9 re-graded Important and addressed in one fix pass. No re-review dispatched.
Final: fixed selecting the active reader mode freezes position — sameReaderModeKeepsPositionEnabled RED→GREEN (behavior failure), suite 93/93.
Final: fixed stale source edits restoring revision/binding — staleSourceCannotRestoreOldBinding RED→GREEN (behavior failure), editPreservesCurrentParserMetadata missing-API RED→GREEN, suite 93/93.
Final: fixed offline image order after refreshed page order — offlineReorderMapsFilesByIdentity RED→GREEN (behavior failure), suite 93/93.
Final: fixed foreign sample binding and source subpath escape — foreignSamplesNeverBind RED→GREEN (behavior failure), sourceSubpathScopeHasSegmentBoundary missing-API RED→GREEN, suite 93/93.
Final: fixed cookie path/expiry loss on requests and redirects — cookiesHonorPathExpiryAndRedirect missing-API RED→GREEN, suite 93/93; WebKit now retains metadata and native scoped transport re-evaluates each redirect/retry.
Final: fixed keyboard spread/scroll navigation — keyboardMovesWholeSpread and scrollKeyboardRequestsVisibleMovement missing-API RED→GREEN, suite 93/93; actual Mac preview RED arrow had no movement before focus fix → GREEN double 2/4→4/4, scroll thumb 0→0.29324, RTL Right 4/4→2/4 and Left 2/4→4/4.
Final: fixed missing entry to readable-only custom sources — readableOnlySourceCanOpenWorkURL missing-API RED→GREEN, suite 93/93; validated sample rows and scoped direct URL entry added.
Final: fixed ambiguity preview request/cache loss — previewsRetainRefererAndDistinctIdentity missing-API RED→GREEN, suite 93/93.
Final: fixed native UI test selectors and readiness — manual Mac accessibility trial RED missing chapter-0/native page controls → GREEN chapter-0 Button/page-zoom/reader-ready and actual chapter/paging actions. Native MangaFlowTests selectors/roles/readiness updated; XCTest execution is pending full Xcode, not claimed green. Portable suite 93/93.
Final: Ruling: native iOS compilation, gestures/layout, sandbox, notifications, relaunch and background expiration were declined by the reviewer — keep as explicitly pending platform acceptance because full Xcode and device runtimes are absent; do not call this a dual-platform release — cost if wrong: platform defects may remain and block release.
Final: Ruling: long-image clarity and whole-process peak memory were declined — retain the documented bounded 4096 ImageIO thumbnail fallback, with real-device acceptance pending — cost if wrong: overly long pages can lose detail or exceed unmeasured memory expectations.
Final: Ruling: source general availability, regions, real expiry and two-work validation were declined — retain limited verification from real single-work first/last-chapter image decoding, with no general availability guarantee — cost if wrong: other works or networks may fail and each site needs broader validation.
Final: Ruling: online CI runner/toolchain availability was declined — keep the documented macOS-15/Xcode-26.2 configuration as unexecuted until remote publication is authorized — cost if wrong: the first online CI run may fail and need configuration repair.
Final: Ruling: guaranteed background timing, paid-content access, sync and arbitrary-site compatibility were declined — these remain outside the approved first-stage scope; background timing is system controlled and only fixed built-in parsers are attempted — cost if wrong: future demand requires separate design and implementation.
Final: minor (deferred): none.
Final verification: latest online probes all readingVerified=true; Guazi browse41/search2/812 chapters, DM5 browse237/search25/4 chapters, Manhuazhan browse136/search verificationRequired/991 chapters. Only one work/site. Latest times14.07s/7.14s/24.93s and maxRSS36.4/37.7/84.1MiB are probe measures, not app/device acceptance.
Final fresh verification: swift run MangaChecks exit0 93/93; swift build --target MangaUI exit0; git diff --check exit0; plist/project lint all OK. swift test and both xcodebuild app builds exit1 because only CLT is installed. Evidence preserved in docs/review-evidence/. Local named branch codex/manga-reader secures worktree commits; no merge/push/publication. Native release acceptance remains open, so finishing-a-development-branch integration menu is not reached.
