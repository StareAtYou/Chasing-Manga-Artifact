import SwiftUI
#if os(macOS)
import AppKit
struct ZoomablePage<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> NSScrollView { let scroll = NSScrollView(); scroll.setAccessibilityIdentifier("page-zoom"); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.allowsMagnification = true; scroll.minMagnification = 0.2; scroll.maxMagnification = 4; scroll.documentView = NSHostingView(rootView: content); return scroll }
    func updateNSView(_ scroll: NSScrollView, context: Context) { guard let host = scroll.documentView as? NSHostingView<Content> else { return }; host.rootView = content; host.layoutSubtreeIfNeeded(); host.setFrameSize(host.fittingSize) }
}
#else
import UIKit
struct ZoomablePage<Content: View>: UIViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeCoordinator() -> Coordinator { Coordinator(content) }
    func makeUIView(context: Context) -> UIScrollView { let scroll = UIScrollView(); scroll.accessibilityIdentifier = "page-zoom"; scroll.minimumZoomScale = 0.2; scroll.maximumZoomScale = 4; scroll.delegate = context.coordinator; let host = context.coordinator.host; host.view.backgroundColor = .clear; scroll.addSubview(host.view); return scroll }
    func updateUIView(_ scroll: UIScrollView, context: Context) { let host = context.coordinator.host; host.rootView = content; let size = host.sizeThatFits(in: CGSize(width: max(1, scroll.bounds.width), height: .greatestFiniteMagnitude)); host.view.frame = CGRect(origin: .zero, size: size); scroll.contentSize = size }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        init(_ content: Content) { host = UIHostingController(rootView: content) }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
    }
}
#endif
