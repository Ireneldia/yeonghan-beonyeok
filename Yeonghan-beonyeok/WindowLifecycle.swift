import AppKit
import SwiftUI

/// Observe this window only; SwiftUI owns the full-window material.
struct WindowLifecycle: NSViewRepresentable {
    var onClose: () -> Void = {}
    func makeNSView(context: Context) -> WindowLifecycleView { WindowLifecycleView() }
    func updateNSView(_ view: WindowLifecycleView, context: Context) { view.onClose = onClose }
}

final class WindowLifecycleView: NSView {
    var onClose: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
    }
    @objc private func windowWillClose() { onClose() }
    deinit { NotificationCenter.default.removeObserver(self) }
}
