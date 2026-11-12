import AppKit
import SwiftUI

/// Mail's pull to refresh: pulling the list down past its top, into the rubber band, calls `onPull` once per pull.
/// Put it behind a `List`; it finds the list's scroll view and watches how far it is pulled.
struct PullToRefresh: NSViewRepresentable {
    let onPull: () -> Void

    func makeNSView(context: Context) -> Detector { Detector(onPull) }
    func updateNSView(_ v: Detector, context: Context) { v.onPull = onPull }

    final class Detector: NSView {
        var onPull: () -> Void
        private weak var scrollView: NSScrollView?
        /// Set again once the list is back at its top, so one pull checks once.
        private var armed = true
        /// How far past the top a pull must go, in points.
        static let threshold: CGFloat = 50

        init(_ onPull: @escaping () -> Void) { self.onPull = onPull; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func layout() {
            super.layout()
            if scrollView == nil { attach() }
        }

        /// The list's scroll view: the table scroll view under this view's centre (the sidebar is one too).
        private func attach() {
            guard scrollView == nil, let root = window?.contentView, bounds.width > 0 else { return }
            let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            guard let sv = Self.tableScrollViews(in: root).first(where: { $0.convert($0.bounds, to: nil).contains(centre) })
            else { return }
            scrollView = sv
            sv.verticalScrollElasticity = .allowed  // as in Mail, a short list bounces too
            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                                   object: sv.contentView)
        }

        @objc private func scrolled() {
            guard let clip = scrollView?.contentView else { return }
            let pulled = -(clip.bounds.origin.y + clip.contentInsets.top)
            if pulled > Self.threshold, armed {
                armed = false
                onPull()
            } else if pulled <= 0 {
                armed = true
            }
        }

        static func detectors(in view: NSView) -> [Detector] {
            (view is Detector ? [view as! Detector] : []) + view.subviews.flatMap(detectors)
        }

        static func tableScrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let sv = view as? NSScrollView, sv.documentView is NSTableView { found.append(sv) }
            for v in view.subviews { found += tableScrollViews(in: v) }
            return found
        }
    }
}
