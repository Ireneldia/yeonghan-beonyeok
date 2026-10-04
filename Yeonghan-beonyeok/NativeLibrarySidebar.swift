import AppKit
import SwiftUI

struct NativeLibrarySidebar: NSViewRepresentable {
    @Binding var location: LibraryLocation
    @Binding var renamingID: UUID?
    var folders: [CourseFolder]
    var onOpen: (LibraryLocation) -> Void
    var onRename: (UUID, String) -> Bool
    var onMenu: (UUID) -> NSMenu
    var onTrashMenu: () -> NSMenu
    var onMove: (Set<UUID>, UUID?) -> Bool
    var onCanMove: (Set<UUID>, UUID?) -> Bool
    var onCanTrash: (Set<UUID>) -> Bool
    var onTrash: (Set<UUID>) -> Bool
    var onDropFiles: ([URL], UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let outline = LibrarySidebarOutlineView()
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.backgroundColor = .clear
        outline.headerView = nil
        outline.allowsEmptySelection = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("location"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.openClickedLocation)
        outline.onRename = { [weak coordinator = context.coordinator] in
            guard let coordinator, let outline = coordinator.outline,
                  let id = (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.folderID else { return }
            coordinator.owner.renamingID = id
            coordinator.beginRename()
        }
        outline.registerForDraggedTypes([NativeLibraryView.dragType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.menuBuilder = { [weak coordinator = context.coordinator] row in
            guard let coordinator, let node = coordinator.outline?.item(atRow: row) as? SidebarNode else { return nil }
            switch node.location {
            case .folder(let id): return coordinator.owner.onMenu(id)
            case .trash: return coordinator.owner.onTrashMenu()
            default: return nil
            }
        }
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var owner: NativeLibrarySidebar
        weak var outline: NSOutlineView?
        private let library = SidebarNode("서재", symbol: "books.vertical", location: .library)
        private let vocabulary = SidebarNode("단어장", symbol: "character.book.closed", location: .vocabulary)
        private let questions = SidebarNode("질문", symbol: "bubble.left.and.bubble.right", location: .questions)
        private let group = SidebarNode("폴더", symbol: nil, location: nil)
        private let trash = SidebarNode("휴지통", symbol: "trash", location: .trash)
        private var roots: [SidebarNode] { [library, vocabulary, questions, trash, group] }
        private var nodes: [UUID: SidebarNode] = [:]
        private var snapshot: [FolderSnapshot] = []
        private var updating = false
        private var dragging = false
        private var pendingOwner: NativeLibrarySidebar?
        private weak var editingField: LibraryNameField?
        private var editingID: UUID?

        init(_ owner: NativeLibrarySidebar) { self.owner = owner }

        func update(_ value: NativeLibrarySidebar) {
            guard let outline else { owner = value; return }
            if dragging { pendingOwner = value; return }
            updating = true
            defer { updating = false }
            owner = value
            if editingID != value.renamingID { editingField?.cancelRenaming() }
            let next = value.folders.map { FolderSnapshot(id: $0.id, name: $0.name, parentID: $0.parentID) }
                .sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
                }
            if next != snapshot || outline.numberOfRows == 0 {
                editingField?.cancelRenaming()
                snapshot = next
                nodes = Dictionary(uniqueKeysWithValues: next.map { folder in
                    let node = nodes[folder.id] ?? SidebarNode(folder.name, symbol: "folder", location: .folder(folder.id))
                    node.title = folder.name
                    node.children = []
                    node.parent = nil
                    return (folder.id, node)
                })
                group.children = []
                for folder in next {
                    guard let node = nodes[folder.id] else { continue }
                    let parent = folder.parentID.flatMap { nodes[$0] } ?? group
                    node.parent = parent
                    parent.children.append(node)
                }
                outline.reloadData()
                outline.expandItem(group)
            }
            let selected: SidebarNode?
            switch value.location {
            case .library: selected = library
            case .vocabulary: selected = vocabulary
            case .questions: selected = questions
            case .trash, .trashFolder: selected = trash
            case .folder(let id): selected = nodes[id]
            }
            if let selected {
                var ancestors: [SidebarNode] = []
                var visited = Set<ObjectIdentifier>()
                var parent = selected.parent
                while let item = parent, visited.insert(ObjectIdentifier(item)).inserted {
                    ancestors.append(item); parent = item.parent
                }
                for item in ancestors.reversed() { outline.expandItem(item) }
                let row = outline.row(forItem: selected)
                if row >= 0 && outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            if value.renamingID != nil && editingID == nil {
                DispatchQueue.main.async { [weak self] in self?.beginRename() }
            }
        }

        fileprivate func beginRename() {
            guard let outline, let id = owner.renamingID, editingID == nil, let node = nodes[id] else { return }
            var ancestors: [SidebarNode] = []
            var visited = Set<ObjectIdentifier>()
            var parent = node.parent
            while let item = parent, visited.insert(ObjectIdentifier(item)).inserted {
                ancestors.append(item); parent = item.parent
            }
            for item in ancestors.reversed() { outline.expandItem(item) }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            outline.scrollRowToVisible(row)
            guard let field = (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell)?.textField as? LibraryNameField,
                  field.window != nil else { return }
            editingID = id; editingField = field
            field.beginRenaming(returnFocus: outline, onCommit: { [weak self] name in
                self?.owner.onRename(id, name) ?? false
            }, onFinish: { [weak self] in
                guard let self else { return }
                self.editingID = nil; self.editingField = nil
                let clear: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self, self.editingID == nil, self.owner.renamingID == id else { return }
                    self.owner.renamingID = nil
                }
                if self.updating { DispatchQueue.main.async(execute: clear) } else { clear() }
            })
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarNode)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? SidebarNode)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return !node.children.isEmpty
        }
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarNode) === group }
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { (item as? SidebarNode) !== group }
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { (item as? SidebarNode) !== group }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarNode)?.location != nil }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(node === group ? "group" : "location")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell
                ?? SidebarCell(isGroup: node === group)
            cell.identifier = identifier
            if (cell.textField as? LibraryNameField)?.isRenaming != true { cell.textField?.stringValue = node.title }
            cell.imageView?.image = node.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            cell.toolTip = node.title
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline,
                  let location = (outline.item(atRow: outline.selectedRow) as? SidebarNode)?.location else { return }
            if owner.location != location { owner.location = location }
        }
        @objc func openClickedLocation() {
            guard let outline, !(outline.window?.firstResponder is NSTextView),
                  let location = (outline.item(atRow: outline.clickedRow) as? SidebarNode)?.location else { return }
            owner.onOpen(location)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard case .folder(let id) = (item as? SidebarNode)?.location else { return nil }
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(id.uuidString, forType: NativeLibraryView.dragType)
            return pasteboard
        }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) { dragging = true }
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dragging = false
                if let value = self.pendingOwner { self.pendingOwner = nil; self.update(value) }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let point = outlineView.convert(info.draggingLocation, from: nil)
            guard let node = outlineView.item(atRow: outlineView.row(at: point)) as? SidebarNode,
                  let target = dropTarget(node) else { return [] }
            let operation: NSDragOperation
            if info.draggingPasteboard.availableType(from: [NativeLibraryView.dragType]) != nil {
                let ids = movingIDs(info.draggingPasteboard)
                guard !ids.isEmpty, info.draggingSourceOperationMask.contains(.move),
                      target === trash ? owner.onCanTrash(ids) : owner.onCanMove(ids, target.folderID) else { return [] }
                operation = .move
            } else {
                guard target !== trash, info.draggingSourceOperationMask.contains(.copy), !pdfURLs(info.draggingPasteboard).isEmpty else { return [] }
                operation = .copy
            }
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            info.animatesToDestination = false
            return operation
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let node = item as? SidebarNode, let target = dropTarget(node) else { return false }
            if info.draggingPasteboard.availableType(from: [NativeLibraryView.dragType]) != nil {
                let ids = movingIDs(info.draggingPasteboard)
                guard !ids.isEmpty else { return false }
                if target === trash { return owner.onCanTrash(ids) && owner.onTrash(ids) }
                guard owner.onCanMove(ids, target.folderID) else { return false }
                return owner.onMove(ids, target.folderID)
            }
            let urls = pdfURLs(info.draggingPasteboard)
            guard target !== trash, !urls.isEmpty else { return false }
            owner.onDropFiles(urls, target.folderID)
            return true
        }
        private func dropTarget(_ node: SidebarNode) -> SidebarNode? {
            switch node.location {
            case .library, .trash: return node
            case .folder(let id) where nodes[id] === node: return node
            default: return nil
            }
        }
        private func movingIDs(_ pasteboard: NSPasteboard) -> Set<UUID> {
            var ids = Set<UUID>()
            for item in pasteboard.pasteboardItems ?? [] {
                guard let value = item.string(forType: NativeLibraryView.dragType), let id = UUID(uuidString: value) else { return [] }
                ids.insert(id)
            }
            return ids
        }
        private func pdfURLs(_ pasteboard: NSPasteboard) -> [URL] {
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                .filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        }
    }
}

private struct FolderSnapshot: Equatable {
    let id: UUID
    let name: String
    let parentID: UUID?
}

private final class SidebarNode: NSObject {
    var title: String
    let symbol: String?
    let location: LibraryLocation?
    var folderID: UUID? { if case .folder(let id) = location { id } else { nil } }
    weak var parent: SidebarNode?
    var children: [SidebarNode] = []
    init(_ title: String, symbol: String?, location: LibraryLocation?) {
        self.title = title; self.symbol = symbol; self.location = location
    }
}

private final class SidebarCell: NSTableCellView {
    init(isGroup: Bool) {
        super.init(frame: .zero)
        let label = LibraryNameField(labelWithString: "")
        label.font = isGroup ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) : .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = isGroup ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        textField = label
        let stack = NSStackView()
        stack.spacing = 6
        stack.alignment = .centerY
        if !isGroup {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageAlignment = .alignCenter
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            imageView = icon
            stack.addArrangedSubview(icon)
        }
        stack.addArrangedSubview(label)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

private final class LibrarySidebarOutlineView: NSOutlineView {
    var menuBuilder: ((Int) -> NSMenu?)?
    var onRename: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onRename?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? menuBuilder?(row) : nil
    }
}
