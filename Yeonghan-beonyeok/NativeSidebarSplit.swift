import AppKit
import SwiftUI

struct NativeSidebarSplit<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    @Binding var isVisible: Bool
    let sidebar: Sidebar
    let detail: Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isVisible: Binding<Bool>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        _isVisible = isVisible; self.sidebar = sidebar(); self.detail = detail()
    }

    func makeNSViewController(context: Context) -> NativeSidebarSplitController {
        NativeSidebarSplitController(sidebar: AnyView(sidebar), detail: AnyView(detail), isVisible: $isVisible)
    }

    func updateNSViewController(_ controller: NativeSidebarSplitController, context: Context) {
        controller.visibility = $isVisible
        controller.sidebarHost.rootView = AnyView(sidebar)
        controller.detailHost.rootView = AnyView(detail)
        controller.applyVisibility(isVisible, reduceMotion: reduceMotion)
        controller.connectToolbar()
    }
}

@MainActor final class NativeSidebarSplitController: NSSplitViewController {
    let sidebarHost: NSHostingController<AnyView>
    let detailHost: NSHostingController<AnyView>
    let sidebarItem: NSSplitViewItem
    var visibility: Binding<Bool>
    private var lastInputVisibility: Bool
    private var collapseObservation: NSKeyValueObservation?

    init(sidebar: AnyView, detail: AnyView, isVisible: Binding<Bool>) {
        visibility = isVisible
        lastInputVisibility = isVisible.wrappedValue
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "LibrarySidebarSplit"
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 175
        sidebarItem.maximumThickness = 280
        sidebarItem.preferredThicknessFraction = 0.2
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.isCollapsed = !isVisible.wrappedValue
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        addSplitViewItem(sidebarItem)
        let contentItem = NSSplitViewItem(viewController: detailHost)
        contentItem.minimumThickness = 726
        addSplitViewItem(contentItem)
        let synchronize: @MainActor @Sendable (Bool) -> Void = { [weak self] collapsed in
            guard let self, self.sidebarItem.isCollapsed == collapsed else { return }
            if self.visibility.wrappedValue == collapsed { self.visibility.wrappedValue = !collapsed }
            self.connectToolbar()
        }
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { _, change in
            guard let collapsed = change.newValue else { return }
            DispatchQueue.main.async { synchronize(collapsed) }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        connectToolbar()
        DispatchQueue.main.async { [weak self] in self?.connectToolbar() }
    }

    @objc func toggleLibrarySidebar(_ sender: Any?) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebarItem.isCollapsed.toggle()
        } else {
            sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleLibrarySidebar(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    func applyVisibility(_ visible: Bool, reduceMotion: Bool) {
        // Do not replay an unchanged binding while AppKit's collapse notification is queued.
        guard visible != lastInputVisibility else { return }
        lastInputVisibility = visible
        guard sidebarItem.isCollapsed == visible else { return }
        if reduceMotion { sidebarItem.isCollapsed = !visible }
        else { toggleLibrarySidebar(nil) }
    }

    func connectToolbar() {
        guard let toolbar = viewIfLoaded?.window?.toolbar else { return }
        for item in toolbar.items where item.itemIdentifier.rawValue == "sidebar" {
            if item.target !== self { item.target = self }
        }
        toolbar.validateVisibleItems()
    }
}
