import SwiftUI
import MangaCore

/// A native scroll container applies row-height changes and the matching offset in one layout pass.
/// Unlike scrollTo restoration, this leaves gestures and deceleration in progress.
struct ReadingViewport: Equatable {
    let offset: CGFloat
    let height: CGFloat
    let intent: Int
    var width: CGFloat = 0
    var interaction: UInt64 = 0
}
struct ReadingScrollDestination {
    let token: UUID
    let rowID: String
    let fraction: Double
    let ready: Bool
}

@MainActor final class ReadingScrollCoordinator {
    var layout = ReadingScrollLayout(rows: [])
    var destinationToken: UUID?
    var destinationReady = false
    var updating = false
    var alive = true
    private var extent: CGFloat = 0
    private var extentViewportHeight: CGFloat = 0
    private var bottomElastic: CGFloat = 0
    var intent = 0
    var interaction: UInt64 = 0
    private var reportedViewport: ReadingViewport?
    private var reportedLayout: ReadingScrollLayout?
    var onScroll: (ReadingViewport) -> Void = { _ in }
    private var pending: ReadingViewport?
    private var scheduled = false

    func offset(for next: ReadingScrollLayout, current: CGFloat, destination: ReadingScrollDestination?) -> CGFloat {
        bottomElastic = extent > 0 ? max(0, current - max(0, extent - extentViewportHeight)) : 0
        var offset = CGFloat(next.preservingOffset(from: layout, offset: current))
        if let destination, destination.token != destinationToken || (destination.ready && !destinationReady),
           let frame = next.frames[destination.rowID] {
            offset = frame.minY + frame.height * destination.fraction
            destinationToken = destination.token; destinationReady = destination.ready; extent = 0; bottomElastic = 0
        }
        if layout != next { extent = 0 }
        layout = next
        return offset
    }
    func contentHeight(viewportHeight: CGFloat, offset: CGFloat) -> CGFloat {
        // A short prepend also needs scrollable room for the preserved positive offset.
        // Retain this extent during the gesture so a shrinking trailing space cannot snap it back.
        if extent == 0 || extentViewportHeight != viewportHeight {
            extent = max(layout.height, max(0, offset - bottomElastic) + viewportHeight)
            extentViewportHeight = viewportHeight
        }
        return extent
    }
    func report(offset: CGFloat, height: CGFloat, width: CGFloat) {
        guard alive, !updating, height > 0 else { return }
        let value = ReadingViewport(offset: offset, height: height, intent: intent, width: width, interaction: interaction)
        guard value != reportedViewport || layout != reportedLayout else { return }
        reportedViewport = value; reportedLayout = layout; pending = value
        guard !scheduled else { return }; scheduled = true
        // Deliver the latest geometry outside the representable update/layout call.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.scheduled = false
            guard self.alive, let value = self.pending else { return }
            self.pending = nil; self.onScroll(value)
        }
    }
    func stop() { alive = false; pending = nil; onScroll = { _ in } }
}

#if os(macOS)
import AppKit
struct StableReadingScrollView<Content: View>: NSViewRepresentable {
    let layout: ReadingScrollLayout
    let width: CGFloat
    let destination: ReadingScrollDestination?
    let onScroll: (ReadingViewport) -> Void
    let content: Content
    func makeCoordinator() -> ReadingScrollCoordinator { ReadingScrollCoordinator() }
    func makeNSView(context: Context) -> NativeReadingScroll {
        let view = NativeReadingScroll()
        view.hasVerticalScroller = true; view.hasHorizontalScroller = false
        view.scrollerStyle = NSScroller.preferredScrollerStyle
        view.autohidesScrollers = view.scrollerStyle != .legacy
        view.drawsBackground = false; view.contentView.drawsBackground = false
        view.automaticallyAdjustsContentInsets = false
        view.setAccessibilityIdentifier("reader-scroll")
        let coordinator = context.coordinator
        view.host = NSHostingView<AnyView>(rootView: AnyView(Color.clear))
        view.host?.safeAreaRegions = []; view.host?.sizingOptions = []; view.host?.isFlipped = true
        view.documentView = view.host
        view.report = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.report(offset: view.contentView.bounds.minY, height: view.contentView.bounds.height, width: view.contentView.bounds.width)
        }
        view.wheel = { [weak coordinator] value in coordinator?.intent = value; coordinator?.interaction &+= 1 }
        view.startObserving()
        return view
    }
    func updateNSView(_ view: NativeReadingScroll, context: Context) {
        let coordinator = context.coordinator; coordinator.onScroll = onScroll; coordinator.updating = true
        // Reserve the legacy scrollbar column; auto-hide must not alternate image width/height.
        view.autohidesScrollers = view.scrollerStyle != .legacy
        let offset = coordinator.offset(for: layout, current: view.contentView.bounds.minY, destination: destination)
        let extent = coordinator.contentHeight(viewportHeight: view.contentView.bounds.height, offset: offset)
        let availableWidth = min(width, view.contentView.bounds.width > 0 ? view.contentView.bounds.width : width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.host?.rootView = AnyView(content.frame(width: availableWidth, height: extent, alignment: .top).transaction { $0.animation = nil; $0.disablesAnimations = true })
        view.host?.setFrameSize(NSSize(width: availableWidth, height: extent))
        view.host?.layoutSubtreeIfNeeded()
        let clamped = min(max(0, offset), max(0, extent - view.contentView.bounds.height))
        if abs(offset - view.contentView.bounds.minY) > 0.5 { view.contentView.scroll(to: NSPoint(x: 0, y: clamped)); view.reflectScrolledClipView(view.contentView) }
        CATransaction.commit(); coordinator.updating = false; view.report?()
    }
    static func dismantleNSView(_ view: NativeReadingScroll, coordinator: ReadingScrollCoordinator) { coordinator.stop(); view.stopObserving() }
}
@MainActor final class NativeReadingScroll: NSScrollView {
    var host: NSHostingView<AnyView>?
    var report: (() -> Void)?
    var wheel: ((Int) -> Void)?
    func startObserving() {
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    func stopObserving() { NotificationCenter.default.removeObserver(self); report = nil; wheel = nil }
    @objc private func boundsChanged() { report?() }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > 0.1 { wheel?(event.scrollingDeltaY < 0 ? 1 : -1) }
        super.scrollWheel(with: event); report?()
    }
    override func layout() { super.layout(); report?() }
}
#else
import UIKit
struct StableReadingScrollView<Content: View>: UIViewRepresentable {
    let layout: ReadingScrollLayout
    let width: CGFloat
    let destination: ReadingScrollDestination?
    let onScroll: (ReadingViewport) -> Void
    let content: Content
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> NativeReadingScroll {
        let view = NativeReadingScroll()
        view.alwaysBounceVertical = true; view.contentInsetAdjustmentBehavior = .never
        view.accessibilityIdentifier = "reader-scroll"; view.delegate = context.coordinator
        let host = UIHostingController(rootView: AnyView(Color.clear))
        host.view.backgroundColor = .clear; host.view.autoresizingMask = []
        host.safeAreaRegions = []
        view.addSubview(host.view); context.coordinator.host = host
        let coordinator = context.coordinator
        view.report = { [weak view, weak coordinator] in if let view { coordinator?.report(view) } }
        return view
    }
    func updateUIView(_ view: NativeReadingScroll, context: Context) {
        let coordinator = context.coordinator; let tracker = coordinator.tracker
        tracker.onScroll = onScroll; tracker.updating = true
        let offset = tracker.offset(for: layout, current: view.contentOffset.y, destination: destination)
        let extent = tracker.contentHeight(viewportHeight: view.bounds.height, offset: offset)
        UIView.performWithoutAnimation {
            coordinator.host?.rootView = AnyView(content.frame(width: width, height: extent, alignment: .top).transaction { $0.animation = nil; $0.disablesAnimations = true })
            coordinator.host?.view.frame = CGRect(x: 0, y: 0, width: width, height: extent)
            coordinator.host?.view.setNeedsLayout(); coordinator.host?.view.layoutIfNeeded()
            view.contentSize = CGSize(width: width, height: extent)
            // Keep the native elastic offset during an unchanged layout/gesture.
            let clamped = min(max(0, offset), max(0, extent - view.bounds.height))
            if abs(offset - view.contentOffset.y) > 0.5 { view.contentOffset.y = clamped }
        }
        tracker.updating = false; coordinator.report(view)
    }
    static func dismantleUIView(_ view: NativeReadingScroll, coordinator: Coordinator) { coordinator.tracker.stop(); view.delegate = nil; view.report = nil }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        let tracker = ReadingScrollCoordinator()
        var host: UIHostingController<AnyView>?
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y
            if !tracker.updating, abs(velocity) > 1 { tracker.intent = velocity < 0 ? 1 : -1; if scrollView.isDragging { tracker.interaction &+= 1 } }
            report(scrollView)
        }
        func report(_ scrollView: UIScrollView) { tracker.report(offset: scrollView.contentOffset.y, height: scrollView.bounds.height, width: scrollView.bounds.width) }
    }
}
@MainActor final class NativeReadingScroll: UIScrollView {
    var report: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); report?() }
}
#endif
