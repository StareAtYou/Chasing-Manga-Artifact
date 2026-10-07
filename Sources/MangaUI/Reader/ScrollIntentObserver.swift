#if os(macOS)
import SwiftUI
import AppKit
/// Observe wheel intent even when short chapters cannot produce a scroll offset.
/// The original event always continues to the native scroll view.
struct ScrollIntentObserver: NSViewRepresentable {
    let onScroll: @MainActor (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }
    func makeNSView(context: Context) -> NSView { let view = NSView(); context.coordinator.attach(view); return view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator {
        weak var view: NSView?
        var onScroll: @MainActor (Int) -> Void
        private var monitor: Any?
        init(onScroll: @escaping @MainActor (Int) -> Void) { self.onScroll = onScroll }
        func attach(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, event.window == view.window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)), abs(event.scrollingDeltaY) > 0.1 else { return event }
                self.onScroll(event.scrollingDeltaY < 0 ? 1 : -1)
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
#endif
