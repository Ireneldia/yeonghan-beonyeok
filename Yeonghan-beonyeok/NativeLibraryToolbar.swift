import AppKit
import SwiftUI

struct NativeLibraryToolbar: NSViewRepresentable {
    @Binding var listMode: Bool
    @Binding var sort: LibrarySort
    @Binding var ascending: Bool
    @Binding var search: String
    var showsBack: Bool
    var showsLibraryControls: Bool
    var allowsNewFolder: Bool
    var exportTitle: String?
    var allowsExport: Bool
    var allowsImport: Bool
    var onBack: () -> Void
    var onNewFolder: () -> Void
    var onImport: () -> Void
    var onExport: (NSWindow) -> Void
    var onSettings: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ToolbarWindowView {
        let view = ToolbarWindowView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateNSView(_ view: ToolbarWindowView, context: Context) {
        context.coordinator.owner = self
        if let window = view.window { context.coordinator.attach(to: window) }
        context.coordinator.update()
    }
    static func dismantleNSView(_ view: ToolbarWindowView, coordinator: Coordinator) {
        if let window = view.window { coordinator.detach(from: window) }
    }

    final class Coordinator: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
        var owner: NativeLibraryToolbar
        private let toolbar = NSToolbar(identifier: "LibraryToolbar")
        private var items: [String: NSToolbarItem] = [:]
        private weak var window: NSWindow?

        init(_ owner: NativeLibraryToolbar) {
            self.owner = owner
            super.init()
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
        }
        func attach(to window: NSWindow) {
            self.window = window
            guard window.toolbar !== toolbar else { return }
            window.toolbarStyle = .unified
            window.toolbar = toolbar
            if let sidebar = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "sidebar" }) {
                sidebar.isNavigational = true
                sidebar.target = splitController(in: window.contentViewController)
            }
            update()
        }
        func detach(from window: NSWindow) {
            if window.toolbar === toolbar { window.toolbar = nil }
            if self.window === window { self.window = nil }
        }
        private func splitController(in controller: NSViewController?) -> NSSplitViewController? {
            guard let controller else { return nil }
            if let split = controller as? NSSplitViewController { return split }
            return controller.children.lazy.compactMap { self.splitController(in: $0) }.first
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            let navigation: [NSToolbarItem.Identifier] = [.init("sidebar"), .init("back"), .flexibleSpace]
            return navigation + ["layout", "sort", "export", "folder", "import", "settings", "search"].map { NSToolbarItem.Identifier($0) }
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if let item = items[identifier.rawValue] { return item }
            let item: NSToolbarItem
            switch identifier.rawValue {
            case "sidebar":
                // The automatic sidebar item requires a sidebar material; this split uses the window backdrop.
                item = button(identifier, "사이드바 전환", "sidebar.left", #selector(NativeSidebarSplitController.toggleLibrarySidebar(_:)))
                item.isNavigational = true
            case "back": item = button(identifier, "뒤로", "chevron.left", #selector(goBack)); item.isNavigational = true
            case "folder": item = button(identifier, "새 폴더", "folder.badge.plus", #selector(newFolder))
            case "import": item = button(identifier, "PDF 추가", "plus", #selector(importPDF))
            case "export": item = button(identifier, "내보내기", "square.and.arrow.up", #selector(export))
            case "settings": item = button(identifier, "설정", "gearshape", #selector(settings))
            case "layout":
                let group = NSToolbarItemGroup(itemIdentifier: identifier,
                    images: ["square.grid.2x2", "list.bullet"].compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) },
                    selectionMode: .selectOne, labels: ["격자", "목록"], target: self, action: #selector(changeLayout))
                group.label = "보기"; item = group
            case "sort":
                let sort = NSMenuToolbarItem(itemIdentifier: identifier)
                sort.label = "정렬"; sort.toolTip = "정렬"
                sort.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "정렬")
                let menu = NSMenu(title: "정렬")
                for criterion in [LibrarySort.name, .dateAdded, .kind, .pageCount] {
                    let option = NSMenuItem(title: criterion.title, action: #selector(changeSort(_:)), keyEquivalent: "")
                    option.target = self; option.representedObject = criterion.rawValue; menu.addItem(option)
                }
                menu.addItem(.separator())
                for (title, ascending) in [("오름차순", true), ("내림차순", false)] {
                    let option = NSMenuItem(title: title, action: #selector(changeDirection(_:)), keyEquivalent: "")
                    option.target = self; option.tag = ascending ? 1 : 0; menu.addItem(option)
                }
                // Assign the complete menu so AppKit does not hide its first appended item as a title.
                sort.menu = menu
                item = sort
            case "search":
                let search = NSSearchToolbarItem(itemIdentifier: identifier)
                search.label = "검색"
                search.searchField.placeholderString = "교안·단어·질문 검색"
                search.searchField.delegate = self
                search.preferredWidthForSearchField = 320
                item = search
            default: return nil // AppKit creates the standard spacing items.
            }
            item.isBordered = true
            items[identifier.rawValue] = item
            return item
        }
        private func button(_ identifier: NSToolbarItem.Identifier, _ title: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = title; item.toolTip = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.target = self; item.action = action; item.autovalidates = false
            return item
        }
        func update() {
            let visibility = ["back": owner.showsBack, "layout": owner.showsLibraryControls,
                              "sort": owner.showsLibraryControls, "folder": owner.allowsNewFolder,
                              "export": owner.exportTitle != nil]
            for (id, visible) in visibility where items[id]?.isHidden != !visible { items[id]?.isHidden = !visible }
            items["import"]?.isEnabled = owner.allowsImport
            items["export"]?.isEnabled = owner.allowsExport
            if let title = owner.exportTitle { items["export"]?.label = title; items["export"]?.toolTip = title }
            if let group = items["layout"] as? NSToolbarItemGroup { group.selectedIndex = owner.listMode ? 1 : 0 }
            if let sort = items["sort"] as? NSMenuToolbarItem {
                for item in sort.menu.items {
                    if let value = item.representedObject as? String {
                        item.state = value == owner.sort.rawValue ? .on : .off
                    } else if item.action == #selector(changeDirection(_:)) {
                        item.state = (item.tag == 1) == owner.ascending ? .on : .off
                    }
                }
            }
            if let search = items["search"] as? NSSearchToolbarItem, search.searchField.stringValue != owner.search {
                search.searchField.stringValue = owner.search
            }
            toolbar.validateVisibleItems()
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { owner.search = field.stringValue }
        }
        @objc private func goBack() { owner.onBack() }
        @objc private func newFolder() { owner.onNewFolder() }
        @objc private func importPDF() { owner.onImport() }
        @objc private func export() {
            guard owner.allowsExport, let window else { return }
            owner.onExport(window)
        }
        @objc private func settings() { owner.onSettings() }
        @objc private func changeLayout() {
            if let group = items["layout"] as? NSToolbarItemGroup { owner.listMode = group.selectedIndex == 1 }
        }
        @objc private func changeSort(_ item: NSMenuItem) {
            guard let value = item.representedObject as? String, let sort = LibrarySort(rawValue: value) else { return }
            guard sort != owner.sort else { return }
            owner.sort = sort
            owner.ascending = sort.defaultAscending
            update()
        }
        @objc private func changeDirection(_ item: NSMenuItem) {
            owner.ascending = item.tag == 1
            update()
        }
    }
}

final class ToolbarWindowView: NSView {
    var attach: ((NSWindow) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { attach?(window) }
    }
}
