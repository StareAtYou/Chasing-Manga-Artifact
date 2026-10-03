# Unified Shelf and Recommendations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Unite downloads with the shelf and add truthful source/category recommendations.

**Architecture:** Keep the existing per-device SQLite store, source adapters and download manager. Add persisted download preparation epochs so shelf removal rejects older asynchronous enqueue attempts. Extend adapters with optional catalog channels and paged listing, then compose a native recommendation page from successful source snapshots.

**Tech Stack:** Swift 6.1, SwiftUI, SwiftSoup 2.13.9, SQLite, Xcode 16.4.

**Spec:** docs/navigation-and-recommendations-design.md (user approved 2026-10-03).

## Global Constraints

- macOS 15.7.7 and iOS 18.5 remain unchanged; minimum macOS 14/iOS 17.
- Local standalone data; no server/accounts/new package dependencies.
- Source scope, authentication and restricted-content handling remain enforced.
- No fabricated popularity/view counts; source ordering and taxonomy remain explicit.
- Signing Team/device identifiers and provisioning material remain local.

## Review Focus

- Removing a grouped work while page preparation is suspended rejects later enqueue and clears every associated source's downloads.
- Legacy downloads whose source is disabled still have a visible shelf owner.
- Changing or disabling a source while recommendation requests run cannot publish stale results.
- Category/pagination URLs cannot cross source scope, accept arbitrary user URLs, or silently return another category.
- Missing rank data, cover images, failed sources and stale cache remain distinguishable from current popular content.

### Task 1: Shelf-owned download lifecycle

**Files:** LibraryStore.swift, DownloadManager.swift, AppContainer+Downloads.swift, AppContainer+Library.swift, new ShelfDownloadChecks.swift and native test wrapper.
**Interfaces:** Store preparation epoch lookup/invalidation and conditional save; manager enqueue/retry optional expected epoch, deleteDownloaded(sourceWorkIDs: Set<SourceWorkID>); existing AppContainer queue methods and removeFromShelf remain source compatible.

- [x] Write checks for single/whole auto-shelf without new following; grouped removal preserving unrelated downloads/history; suspended preparation removal and explicit re-download; legacy migration with disabled source.
- [x] Observe expected assertion failures through Swift Testing.
- [x] Make conditional task save + shelf ownership atomic; invalidate epochs before cancellation/deletion, preserve failed-cleanup visibility.
- [x] Run whole suite and shared checks; commit only task files.

### Task 2: Real source catalog channels

**Files:** new CatalogRecommendationModels.swift and HTMLCatalogDiscovery.swift; SourceAdapter.swift, SourceService.swift; relevant built-in adapters; new CatalogRecommendationChecks.swift/native wrapper.
**Interfaces:** CatalogChannel(id,title,url,kind), CatalogPage(works,nextURL), SourceRecommendations(sourceID,revision,channels,sections,fetchedAt). Adapter recommendations(context:)/catalogPage(channel:pageURL:context:) with safe defaults. SourceService recommendations(sourceID:)/catalogPage(sourceID:channelID:pageURL:) validate current persisted snapshot and source revision.

- [x] Pin synthetic fixtures based on actual public structures: genuine category links, popular sections versus latest updates, next-page identity, external-link rejection, unsupported source fallback.
- [x] Observe RED, then implement normalized taxonomy and source-scoped channel discovery with bounded source requests.
- [x] Add supported homepage/category/ranking integration for MangaBZ, DM5, Baozi, ComicFury and MangaDex; other adapters expose actual available browsing/series data.
- [x] Persist successful snapshots, preserve partial source successes, prevent changed/disabled source responses publishing; verify fixtures and bounded real website probes.
- [x] Run whole suite/shared checks and commit task files.

### Task 3: Native navigation and recommendation browsing

**Files:** AppContainer.swift/new +Recommendations.swift, RootNavigation.swift, LibraryView.swift, WorkDetailView.swift, ChapterListView.swift, DownloadsView.swift, DiscoveryView.swift; new Recommendations directory views; UITestBootstrap.swift; docs/package version files.
**Interfaces:** AppSection library/recommendations/discovery/updates; app shelf download presentation with optional WorkID filter; recommendations snapshots/loading/errors and selected category/channel routes; existing select/open/reader navigation reused.

- [x] Connect shelf filters/status summaries and download management; every removal affordance explains deletion before user confirms.
- [x] Remove source-management cards from Discovery, preserve source search filtering and management/link entry points.
- [x] Build responsive large feature cards, source-labelled popular rails, real genre/source columns and paginated channel pages; no fake global rank.
- [x] Check local native fixture navigation, recommendation/category/page selection, download auto-shelf/removal/offline reading via UI.
- [x] Run regression suite, Mac universal and iOS18.5 Release builds; fresh whole-branch review and one verified fix pass for material findings.
- [x] Sanitize staged project/signing identifiers; scan public files and commit range, push authorized remote, sync primary checkout, deliver versioned source/Mac/IPA archives and install/launch on original device if available.

## Execution Notes

Implement inline in the established managed worktree. Design has explicit user approval; routine implementation decisions stay within it. Existing authorization covers delivery, same-device installation and sanitized remote commits. Do not repeat approval between tasks. Verification logs/ledger live in ignored workspace files.
