import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeLibraryView: NSViewRepresentable {
    static let dragType = NSPasteboard.PasteboardType("org.yeonghan.document")
    var entries: [LibraryEntry]
    @Binding var selection: Set<UUID>
    @Binding var renamingID: UUID?
    var listMode: Bool
    @Binding var sort: LibrarySort
    @Binding var ascending: Bool
    var iconSize: Double = 64
    var currentFolderID: UUID? = nil
    var allowsRenaming = true
    var allowsFileDrops = true
    var onOpen: (UUID) -> Void
    var onRename: (UUID, String) -> Bool
    var onMenu: (LibraryEntry, Set<UUID>) -> NSMenu
    var onBackgroundMenu: () -> NSMenu?
    var onDropFiles: ([URL], UUID?) -> Void
    var onCanMove: (Set<UUID>, UUID?) -> Bool
    var onMove: (Set<UUID>, UUID?) -> Bool
    var onDelete: (Set<UUID>) -> Void

    private var gridIconSize: CGFloat { CGFloat(min(128, max(32, iconSize))) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        context.coordinator.scroll = scroll
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSTableViewDataSource, NSTableViewDelegate {
        var owner: NativeLibraryView
        weak var scroll: NSScrollView?
        weak var collection: FileCollectionView?
        weak var table: FileTableView?
        private var defersUpdates = false
        private var pendingOwner: NativeLibraryView?
        private var updating = false
        private weak var editingField: LibraryNameField?
        private var editingID: UUID?
        init(_ owner: NativeLibraryView) { self.owner = owner }
        private func install(in scroll: NSScrollView) {
            let open: (Int) -> Void = { [weak self] index in
                guard let self, self.owner.entries.indices.contains(index) else { return }
                self.owner.onOpen(self.owner.entries[index].id)
            }
            let menu: (Int) -> NSMenu? = { [weak self] index in
                guard let self else { return nil }
                guard self.owner.entries.indices.contains(index) else { return self.owner.onBackgroundMenu() }
                let item = self.owner.entries[index]
                let ids = self.owner.selection.contains(item.id) ? self.owner.selection : [item.id]
                self.owner.selection = ids
                return self.owner.onMenu(item, ids)
            }
            let delete: () -> Void = { [weak self] in
                guard let self else { return }; self.owner.onDelete(self.owner.selection)
            }
            let rename: (Int) -> Void = { [weak self] index in
                guard let self, self.owner.allowsRenaming, self.owner.entries.indices.contains(index) else { return }
                self.owner.renamingID = self.owner.entries[index].id
                self.beginRename()
            }
            if owner.listMode {
                let table = FileTableView()
                table.style = .fullWidth
                table.rowSizeStyle = .small
                table.backgroundColor = .clear
                table.allowsMultipleSelection = true
                table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
                for (sort, width) in [(LibrarySort.name, 300.0), (.kind, 100.0), (.pageCount, 70.0), (.dateAdded, 150.0)] {
                    let column = NSTableColumn(identifier: .init(sort.rawValue))
                    column.title = sort.title; column.width = width; column.minWidth = sort == .name ? 140 : 60
                    column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: sort.defaultAscending)
                    table.addTableColumn(column)
                }
                table.autosaveName = "LibraryTableColumns"
                table.autosaveTableColumns = true
                table.dataSource = self; table.delegate = self
                table.target = table; table.doubleAction = #selector(FileTableView.openClickedRow)
                table.onOpen = open; table.menuBuilder = menu; table.onDelete = delete
                table.onRename = rename
                table.registerForDraggedTypes([NativeLibraryView.dragType, .fileURL])
                table.setDraggingSourceOperationMask(.move, forLocal: true)
                table.setDraggingSourceOperationMask([], forLocal: false)
                scroll.hasHorizontalScroller = true
                scroll.documentView = table
                self.collection = nil; self.table = table
            } else {
                let collection = FileCollectionView()
                collection.backgroundColors = [.clear]
                // Install the modern layout before registering reusable items.
                collection.collectionViewLayout = NSCollectionViewFlowLayout()
                collection.isSelectable = true; collection.allowsMultipleSelection = true
                collection.allowsEmptySelection = true
                collection.register(FileCollectionItem.self, forItemWithIdentifier: .init("file"))
                collection.dataSource = self; collection.delegate = self
                collection.onOpen = open; collection.menuBuilder = menu; collection.onDelete = delete
                collection.onRename = rename
                collection.registerForDraggedTypes([NativeLibraryView.dragType, .fileURL])
                collection.setDraggingSourceOperationMask(.move, forLocal: true)
                collection.setDraggingSourceOperationMask([], forLocal: false)
                scroll.hasHorizontalScroller = false
                scroll.documentView = collection
                self.table = nil; self.collection = collection
            }
        }
        func update(_ value: NativeLibraryView) {
            guard let scroll else { owner = value; return }
            if defersUpdates { pendingOwner = value; return }
            updating = true
            defer { updating = false }
            let old = owner
            let selected = value.selection
            let structureChanged = old.entries.map(\.id) != value.entries.map(\.id) || old.listMode != value.listMode
            let iconSizeChanged = old.gridIconSize != value.gridIconSize && !value.listMode
            owner = value
            if structureChanged || editingID != value.renamingID { editingField?.cancelRenaming() }
            if old.listMode != value.listMode || scroll.documentView == nil { install(in: scroll) }
            if let collection {
                if structureChanged || collection.numberOfItems(inSection: 0) != value.entries.count {
                    collection.reloadData()
                    collection.needsLayout = true
                } else {
                    for (index, entry) in value.entries.enumerated() where old.entries[index] != entry || iconSizeChanged {
                        (collection.item(at: IndexPath(item: index, section: 0)) as? FileCollectionItem)?.configure(entry, iconSize: value.gridIconSize)
                    }
                    if iconSizeChanged { collection.invalidateItemSizes() }
                }
                let paths = Set(value.entries.enumerated().filter { selected.contains($0.element.id) }.map { IndexPath(item: $0.offset, section: 0) })
                if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
            }
            if let table {
                if structureChanged || table.numberOfRows != value.entries.count { table.reloadData() }
                else {
                    let changed = IndexSet(value.entries.indices.filter { old.entries[$0] != value.entries[$0] })
                    if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
                }
                let rows = IndexSet(value.entries.indices.filter { selected.contains(value.entries[$0].id) })
                if table.selectedRowIndexes != rows { table.selectRowIndexes(rows, byExtendingSelection: false) }
                if table.sortDescriptors.count != 1 || table.sortDescriptors.first?.key != value.sort.rawValue || table.sortDescriptors.first?.ascending != value.ascending {
                    table.sortDescriptors = [NSSortDescriptor(key: value.sort.rawValue, ascending: value.ascending)]
                }
            }
            let visibleIDs = Set(value.entries.map(\.id))
            if !selected.isSubset(of: visibleIDs) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.owner.selection == selected else { return }
                    self.owner.selection = selected.intersection(Set(self.owner.entries.map(\.id)))
                }
            }
            if value.renamingID != nil && editingID == nil {
                DispatchQueue.main.async { [weak self] in self?.beginRename() }
            }
        }
        private func beginRename() {
            guard owner.allowsRenaming, let id = owner.renamingID, editingID == nil,
                  let index = owner.entries.firstIndex(where: { $0.id == id }) else { return }
            let field: LibraryNameField?
            let focus: NSView?
            var width: CGFloat?
            if let collection {
                let path = IndexPath(item: index, section: 0)
                collection.layoutSubtreeIfNeeded()
                if let frame = collection.layoutAttributesForItem(at: path)?.frame {
                    collection.scrollToVisible(frame)
                }
                collection.layoutSubtreeIfNeeded()
                let item = collection.item(at: path)
                field = item?.textField as? LibraryNameField
                width = item.map { max(80, $0.view.bounds.width - 24) }
                focus = collection
            } else if let table {
                let nameColumn = table.column(withIdentifier: .init(LibrarySort.name.rawValue))
                guard nameColumn >= 0 else { return }
                table.scrollRowToVisible(index)
                table.scrollColumnToVisible(nameColumn)
                field = (table.view(atColumn: nameColumn, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField as? LibraryNameField
                focus = table
            } else { return }
            guard let field, let focus, field.window != nil else { return }
            editingID = id; editingField = field
            field.beginRenaming(returnFocus: focus, width: width, onCommit: { [weak self] name in
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
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { owner.entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("file"), for: indexPath) as! FileCollectionItem
            let entry = owner.entries[indexPath.item]
            item.configure(entry, iconSize: owner.gridIconSize)
            item.menuProvider = { [weak self] in
                guard let self else { return nil }
                let ids = self.owner.selection.contains(entry.id) ? self.owner.selection : [entry.id]
                self.owner.selection = ids
                return self.owner.onMenu(entry, ids)
            }
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            guard editingID == nil, owner.entries.indices.contains(indexPath.item),
                  owner.renamingID == owner.entries[indexPath.item].id else { return }
            DispatchQueue.main.async { [weak self] in self?.beginRename() }
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            NSSize(width: owner.gridIconSize + 88, height: owner.gridIconSize + 96)
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                            insetForSectionAt section: Int) -> NSEdgeInsets { .init(top: 16, left: 16, bottom: 16, right: 16) }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { sync(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { sync(collectionView) }
        private func sync(_ view: NSCollectionView) {
            guard !updating else { return }
            owner.selection = Set(view.selectionIndexPaths.compactMap { owner.entries.indices.contains($0.item) ? owner.entries[$0.item].id : nil })
        }
        func numberOfRows(in tableView: NSTableView) -> Int { owner.entries.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            owner.selection = Set(table.selectedRowIndexes.compactMap { owner.entries.indices.contains($0) ? owner.entries[$0].id : nil })
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let sort = LibrarySort(rawValue: key) else { return }
            owner.sort = sort; owner.ascending = descriptor.ascending
        }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            owner.entries[row].title
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, let sort = LibrarySort(rawValue: column.identifier.rawValue) else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView { cell = reused }
            else {
                cell = NSTableCellView(); cell.identifier = column.identifier
                let text = sort == .name ? LibraryNameField(labelWithString: "") : NSTextField(labelWithString: "")
                text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                text.lineBreakMode = sort == .name ? .byTruncatingMiddle : .byTruncatingTail
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text); cell.textField = text
                var leading = cell.leadingAnchor
                if sort == .name {
                    let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
                    icon.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(icon); cell.imageView = icon
                    NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                                 icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                                 icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
                    leading = icon.trailingAnchor
                }
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: leading, constant: 4),
                                             text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                             text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let entry = owner.entries[row]
            switch sort {
            case .name:
                if (cell.textField as? LibraryNameField)?.isRenaming != true { cell.textField?.stringValue = entry.title }
                cell.imageView?.image = NSWorkspace.shared.icon(for: entry.isFolder ? .folder : .pdf)
            case .kind: cell.textField?.stringValue = entry.kind
            case .pageCount: cell.textField?.stringValue = entry.pageCount.map(String.init) ?? "—"
            case .dateAdded: cell.textField?.stringValue = entry.createdAt?.formatted(date: .numeric, time: .omitted) ?? "—"
            }
            cell.toolTip = cell.textField?.stringValue
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            pasteboardWriter(at: indexPath.item)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { pasteboardWriter(at: row) }
        private func pasteboardWriter(at index: Int) -> NSPasteboardWriting? {
            let entry = owner.entries[index]
            let item = NSPasteboardItem(); item.setString(entry.id.uuidString, forType: NativeLibraryView.dragType)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            defersUpdates = true
        }
        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            finishDragging()
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            defersUpdates = true
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishDragging()
        }
        private func finishDragging() {
            // Let AppKit finish restoring its dragged views before applying a changed data snapshot.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.defersUpdates = false
                if let value = self.pendingOwner { self.pendingOwner = nil; self.update(value) }
            }
        }
        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            let index = dropIndex(draggingInfo, in: collectionView)
            // Folder/import drops must not create a collection reordering gap.
            proposedDropIndexPath.pointee = NSIndexPath(forItem: index >= 0 ? index : owner.entries.count, inSection: 0)
            proposedDropOperation.pointee = .on
            return validateDrop(draggingInfo, at: index)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let targetRow = dropIndex(info, in: tableView)
            // A document or blank-space drop targets the current folder, never a row insertion.
            tableView.setDropRow(targetRow, dropOperation: .on)
            return validateDrop(info, at: targetRow)
        }
        private func validateDrop(_ draggingInfo: any NSDraggingInfo, at index: Int) -> NSDragOperation {
            let target = targetFolder(at: index)
            let pasteboard = draggingInfo.draggingPasteboard
            let operation: NSDragOperation
            if pasteboard.availableType(from: [NativeLibraryView.dragType]) != nil {
                let ids = draggedIDs(pasteboard)
                guard !ids.isEmpty, owner.onCanMove(ids, target), draggingInfo.draggingSourceOperationMask.contains(.move) else { return [] }
                operation = .move
            } else {
                guard owner.allowsFileDrops, !pdfURLs(pasteboard).isEmpty, draggingInfo.draggingSourceOperationMask.contains(.copy) else { return [] }
                operation = .copy
            }
            draggingInfo.animatesToDestination = false
            return operation
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            acceptDrop(draggingInfo, at: dropIndex(draggingInfo, in: collectionView))
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            acceptDrop(info, at: dropIndex(info, in: tableView))
        }
        private func acceptDrop(_ draggingInfo: any NSDraggingInfo, at index: Int) -> Bool {
            let target = targetFolder(at: index)
            let pasteboard = draggingInfo.draggingPasteboard
            if pasteboard.availableType(from: [NativeLibraryView.dragType]) != nil {
                let ids = draggedIDs(pasteboard)
                guard !ids.isEmpty, owner.onCanMove(ids, target) else { return false }
                return owner.onMove(ids, target)
            }
            guard owner.allowsFileDrops else { return false }
            let urls = pdfURLs(pasteboard)
            guard !urls.isEmpty else { return false }
            owner.onDropFiles(urls, target); return true
        }

        private func targetFolder(at index: Int) -> UUID? {
            owner.entries.indices.contains(index) && owner.entries[index].isFolder ? owner.entries[index].id : owner.currentFolderID
        }

        private func dropIndex(_ info: any NSDraggingInfo, in collection: NSCollectionView) -> Int {
            let point = collection.convert(info.draggingLocation, from: nil)
            guard let path = collection.indexPathForItem(at: point),
                  owner.entries.indices.contains(path.item), owner.entries[path.item].isFolder else { return -1 }
            return path.item
        }

        private func dropIndex(_ info: any NSDraggingInfo, in table: NSTableView) -> Int {
            let point = table.convert(info.draggingLocation, from: nil)
            let row = table.row(at: point)
            guard owner.entries.indices.contains(row), owner.entries[row].isFolder,
                  table.rect(ofRow: row).insetBy(dx: 0, dy: table.intercellSpacing.height / 2).contains(point) else { return -1 }
            return row
        }

        private func draggedIDs(_ pasteboard: NSPasteboard) -> Set<UUID> {
            Set((pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: NativeLibraryView.dragType).flatMap(UUID.init(uuidString:)) })
        }

        private func pdfURLs(_ pasteboard: NSPasteboard) -> [URL] {
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                .filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
        }
    }

}

final class FileCollectionView: NSCollectionView, NSGestureRecognizerDelegate {
    var onOpen: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var menuBuilder: ((Int) -> NSMenu?)?
    var onDelete: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let click = NSClickGestureRecognizer(target: self, action: #selector(openClickedItem(_:)))
        click.numberOfClicksRequired = 2
        // Let AppKit handle selection and dragging while recognizing a double-click.
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = self
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if window?.firstResponder is NSTextView { return false }
        return event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
            && !(hitTest(point) is NSButton) && indexPathForItem(at: point) != nil
    }
    @objc private func openClickedItem(_ gesture: NSClickGestureRecognizer) {
        guard let index = indexPathForItem(at: gesture.location(in: self))?.item else { return }
        // Finish AppKit selection before opening the reader.
        DispatchQueue.main.async { [weak self] in self?.onOpen?(index) }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.width != newSize.width
        super.setFrameSize(newSize)
        if changed { invalidateItemSizes() }
    }
    func invalidateItemSizes() {
        let context = NSCollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutDelegateMetrics = true
        context.invalidateFlowLayoutAttributes = true
        collectionViewLayout?.invalidateLayout(with: context)
        needsLayout = true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        menuBuilder?(indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item ?? -1)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if (event.keyCode == 36 || event.keyCode == 76), selectionIndexPaths.count == 1,
           let index = selectionIndexPaths.first?.item { onRename?(index); return }
        super.keyDown(with: event)
    }
}

final class FileTableView: NSTableView {
    var onOpen: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var menuBuilder: ((Int) -> NSMenu?)?
    var onDelete: (() -> Void)?

    @objc func openClickedRow() { if clickedRow >= 0, !(window?.firstResponder is NSTextView) { onOpen?(clickedRow) } }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return menuBuilder?(row)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if (event.keyCode == 36 || event.keyCode == 76), selectedRowIndexes.count == 1 { onRename?(selectedRow); return }
        super.keyDown(with: event)
    }
}

final class FileCollectionItem: NSCollectionViewItem {
    var menuProvider: (() -> NSMenu?)?
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let pdfIcon = NSWorkspace.shared.icon(for: .pdf)
    private let iconSelection = NSVisualEffectView()
    private let titleSelection = NSVisualEffectView()
    private let menuButton = NSButton()
    private let symbol = NSImageView()
    private let titleLabel = LibraryNameField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let textStack = NSStackView()
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?
    override func loadView() {
        view = NSView()
        for background in [iconSelection, titleSelection] {
            background.material = .selection
            background.blendingMode = .withinWindow
            background.isEmphasized = background !== iconSelection
            view.addSubview(background)
        }
        iconSelection.wantsLayer = true; iconSelection.layer?.cornerRadius = 6; iconSelection.layer?.masksToBounds = true
        titleSelection.wantsLayer = true; titleSelection.layer?.cornerRadius = 4; titleSelection.layer?.masksToBounds = true
        iconSelection.translatesAutoresizingMaskIntoConstraints = false
        titleSelection.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium); titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
        textStack.addArrangedSubview(titleLabel); textStack.addArrangedSubview(subtitle)
        textStack.orientation = .vertical; textStack.spacing = 4; textStack.alignment = .centerX
        stack.orientation = .vertical; stack.alignment = .centerX
        stack.addArrangedSubview(symbol); stack.addArrangedSubview(textStack); stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "항목 메뉴")
        menuButton.isBordered = false; menuButton.target = self; menuButton.action = #selector(showMenu)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([menuButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
                                     menuButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                                     menuButton.widthAnchor.constraint(equalToConstant: 22), menuButton.heightAnchor.constraint(equalToConstant: 22)])
        iconWidth = symbol.widthAnchor.constraint(equalToConstant: 42); iconWidth?.isActive = true
        iconHeight = symbol.heightAnchor.constraint(equalToConstant: 42); iconHeight?.isActive = true
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                                     stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                                     stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                                     iconSelection.centerXAnchor.constraint(equalTo: symbol.centerXAnchor),
                                     iconSelection.centerYAnchor.constraint(equalTo: symbol.centerYAnchor),
                                     iconSelection.widthAnchor.constraint(equalTo: symbol.widthAnchor, constant: 12),
                                     iconSelection.heightAnchor.constraint(equalTo: symbol.heightAnchor, constant: 12),
                                     titleSelection.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -4),
                                     titleSelection.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
                                     titleSelection.topAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -2),
                                     titleSelection.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)])
        imageView = symbol
        textField = titleLabel
    }
    func configure(_ item: LibraryEntry, iconSize: CGFloat) {
        if !titleLabel.isRenaming { titleLabel.stringValue = item.title }
        subtitle.stringValue = item.subtitle
        symbol.image = item.isFolder ? Self.folderIcon : Self.pdfIcon
        symbol.imageScaling = .scaleProportionallyUpOrDown
        iconWidth?.constant = iconSize; iconHeight?.constant = iconSize
        menuButton.setAccessibilityLabel("\(item.title) 메뉴")
        view.setAccessibilityLabel(item.title); view.toolTip = item.title
        updateSelection()
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }
    @objc private func showMenu() { menuProvider?()?.popUp(positioning: nil, at: NSPoint(x: menuButton.bounds.maxX, y: 0), in: menuButton) }
    private func updateSelection() {
        let selected = highlightState == .forSelection || highlightState == .asDropTarget
            || (isSelected && highlightState != .forDeselection)
        iconSelection.isHidden = !selected
        titleSelection.isHidden = !selected
        if !titleLabel.isRenaming { titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor }
    }
}

/// Uses the window's normal field editor for in-place Finder-style renaming.
final class LibraryNameField: NSTextField, NSTextFieldDelegate {
    private(set) var isRenaming = false
    private var originalName = ""
    private var originalColor: NSColor?
    private var editingWidth: NSLayoutConstraint?
    private weak var returnFocus: NSView?
    private var onCommit: ((String) -> Bool)?
    private var onFinish: (() -> Void)?
    private var validating = false

    func beginRenaming(returnFocus: NSView, width: CGFloat? = nil,
                       onCommit: @escaping (String) -> Bool, onFinish: @escaping () -> Void) {
        guard !isRenaming, let window else { return }
        originalName = stringValue; originalColor = textColor
        self.returnFocus = returnFocus; self.onCommit = onCommit; self.onFinish = onFinish
        isRenaming = true; delegate = self
        isEditable = true; isSelectable = true; isBordered = true; drawsBackground = true
        backgroundColor = .textBackgroundColor; textColor = .textColor
        if let width { editingWidth = widthAnchor.constraint(equalToConstant: width); editingWidth?.isActive = true }
        returnFocus.layoutSubtreeIfNeeded()
        if window.makeFirstResponder(self) { currentEditor()?.selectedRange = NSRange(location: 0, length: (stringValue as NSString).length) }
        else { cancelRenaming() }
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard isRenaming else { return true }
        guard !validating else { return false }
        validating = true
        defer { validating = false }
        return fieldEditor.string == originalName || (onCommit?(fieldEditor.string) ?? false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRenaming(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(returnFocus); return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRenaming() }

    func cancelRenaming() {
        guard isRenaming else { return }
        let focus = returnFocus
        isRenaming = false
        abortEditing()
        stringValue = originalName
        finishRenaming()
        window?.makeFirstResponder(focus)
    }

    private func finishRenaming() {
        guard onFinish != nil else { return }
        isRenaming = false
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        textColor = originalColor; editingWidth?.isActive = false; editingWidth = nil
        delegate = nil; onCommit = nil; returnFocus = nil
        let finish = onFinish; onFinish = nil
        finish?()
    }
}
