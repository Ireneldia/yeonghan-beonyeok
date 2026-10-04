import AppKit
import CryptoKit
import PDFKit
import SwiftData
import Observation

nonisolated struct PDFImport: Sendable {
    let id: UUID
    let name: String
    let fingerprint: String
    let pageCount: Int
    let stagingURL: URL
}

nonisolated enum LibraryError: LocalizedError {
    case invalidName, unsupportedPDF, lockedPDF, invalidFolder, invalidSelection, duplicateFolderName, recoveryNeeded
    var errorDescription: String? {
        switch self {
        case .invalidName: "이름을 1~200자로 입력하세요."
        case .unsupportedPDF: "읽을 수 있는 PDF 파일을 선택하세요."
        case .lockedPDF: "암호가 걸린 PDF입니다. 암호를 해제한 파일을 추가하세요."
        case .invalidFolder: "폴더 위치가 올바르지 않거나 사용할 수 없습니다."
        case .invalidSelection: "선택한 항목이 변경됐거나 휴지통에 있습니다. 목록을 다시 확인하세요."
        case .duplicateFolderName: "같은 위치에 같은 이름의 폴더가 있습니다. 다른 이름을 입력하세요."
        case .recoveryNeeded: "삭제 작업의 파일 복구가 필요합니다. 앱 저장 폴더의 Staging 파일을 보존하세요."
        }
    }
}

nonisolated private struct PendingFileDeletion: Codable {
    let directory: String
    let filename: String
    let stagedFilename: String
    let wasPresent: Bool
}

nonisolated private struct LibraryItemLocation {
    let id: UUID
    let isFolder: Bool
    let parentID: UUID?
}

@Observable @MainActor
final class LibraryStore {
    let container: ModelContainer
    let context: ModelContext
    let directory: URL
    var documents: [LectureDocument] = []
    var folders: [CourseFolder] = []
    var lookups: [LookupRecord] = []
    var questions: [QuestionRecord] = []
    var error: String?
    var isImporting = false
    var importProgress = ""

    init(container: ModelContainer, directory: URL) throws {
        self.container = container
        self.context = container.mainContext
        self.directory = directory
        for child in ["Documents", "Staging", "Recordings"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(child), withIntermediateDirectories: true)
        }
        try reload()
        do {
            try recoverPendingDeletions()
            try removeAbandonedImports()
        }
        catch { self.error = error.localizedDescription }
    }

    static func dataDirectory() throws -> URL {
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
            .appendingPathComponent("Yeonghan-beonyeok", isDirectory: true)
    }

    func reload() throws {
        let documents = try context.fetch(FetchDescriptor<LectureDocument>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let folders = try context.fetch(FetchDescriptor<CourseFolder>(sortBy: [SortDescriptor(\.name)]))
        let lookups = try context.fetch(FetchDescriptor<LookupRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        let questions = try context.fetch(FetchDescriptor<QuestionRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        self.documents = documents; self.folders = folders
        self.lookups = lookups; self.questions = questions
    }

    func save() throws {
        try saveChanges()
        // A failed refresh must not make callers undo files after the DB commit succeeded.
        do { try reload() }
        catch { self.error = "저장은 완료됐지만 목록을 갱신하지 못했습니다: \(error.localizedDescription)" }
    }

    func saveReadingPosition(document: LectureDocument, page: Int) throws {
        let id = document.id
        guard let stored = documents.first(where: { $0.id == id && $0.trashedAt == nil }) else { throw LibraryError.invalidSelection }
        guard stored.lastPage != page else { return }
        stored.lastPage = page
        try saveChanges()
    }

    private func saveChanges() throws {
        do { try context.save() }
        catch { context.rollback(); try? reload(); throw error }
    }

    func url(for document: LectureDocument) -> URL {
        directory.appendingPathComponent("Documents").appendingPathComponent(document.filename)
    }

    nonisolated static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !trimmed.isEmpty, trimmed.count <= 200,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LibraryError.invalidName }
        return trimmed
    }

    func addFolder(parentID: UUID? = nil) throws -> CourseFolder {
        try requireActiveFolder(parentID)
        let siblings = try context.fetch(FetchDescriptor<CourseFolder>()).filter { $0.trashedAt == nil && $0.parentID == parentID }
        var name = "새 폴더", suffix = 2
        while siblings.contains(where: { Self.sameName($0.name, name) }) {
            name = "새 폴더 \(suffix)"; suffix += 1
        }
        let folder = CourseFolder(name: name, parentID: parentID)
        context.insert(folder)
        try save()
        return folder
    }

    func rename(document: LectureDocument, to name: String, undo: UndoManager? = nil) throws {
        let old = document.name
        document.name = try Self.validName(name); try save()
        undo?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { do { try store.rename(document: document, to: old, undo: undo) } catch { store.error = error.localizedDescription } }
        }
        undo?.setActionName("교안 이름 변경")
    }

    func rename(folder: CourseFolder, to name: String) throws {
        try requireActiveFolder(folder.id)
        folder.name = try uniqueFolderName(name, parentID: folder.parentID, excluding: folder.id); try save()
    }

    private func uniqueFolderName(_ name: String, parentID: UUID?, excluding id: UUID? = nil) throws -> String {
        let name = try Self.validName(name)
        let existing = try context.fetch(FetchDescriptor<CourseFolder>())
        guard !existing.contains(where: { $0.id != id && $0.trashedAt == nil && $0.parentID == parentID && Self.sameName($0.name, name) }) else {
            throw LibraryError.duplicateFolderName
        }
        return name
    }

    private func requireActiveFolder(_ id: UUID?) throws {
        guard id != nil else { return }
        let existing = try context.fetch(FetchDescriptor<CourseFolder>())
        guard Self.activePath(id, in: Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })) else { throw LibraryError.invalidFolder }
    }

    func move(_ ids: Set<UUID>, to folderID: UUID?, undo: UndoManager? = nil) throws {
        guard !ids.isEmpty else { return }
        try reload()
        try applyLocations(moveLocations(ids, to: folderID), undo: undo)
    }

    func canMove(_ ids: Set<UUID>, to folderID: UUID?) -> Bool {
        guard !ids.isEmpty else { return false }
        do { try validateLocations(moveLocations(ids, to: folderID)); return true }
        catch { return false }
    }

    func descendantFolderIDs(of ids: Set<UUID>) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for folder in folders { if let parent = folder.parentID { children[parent, default: []].append(folder.id) } }
        var result = ids.intersection(Set(folders.map(\.id)))
        var pending = Array(result)
        while let id = pending.popLast() {
            for child in children[id] ?? [] where result.insert(child).inserted { pending.append(child) }
        }
        return result
    }

    func folderPath(_ id: UUID) -> String {
        Self.folderPath(id, in: Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) }))
    }

    var folderPaths: [UUID: String] {
        let lookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        return lookup.mapValues { Self.folderPath($0.id, in: lookup) }
    }

    private static func folderPath(_ id: UUID, in lookup: [UUID: CourseFolder]) -> String {
        var next: UUID? = id, seen: Set<UUID> = [], names: [String] = []
        while let current = next, seen.insert(current).inserted, let folder = lookup[current] {
            names.append(folder.name); next = folder.parentID
        }
        return names.reversed().joined(separator: " / ")
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.precomposedStringWithCanonicalMapping.compare(rhs.precomposedStringWithCanonicalMapping, options: .caseInsensitive) == .orderedSame
    }

    private static func activePath(_ id: UUID?, in lookup: [UUID: CourseFolder], locations: [UUID: LibraryItemLocation] = [:]) -> Bool {
        var next = id, seen: Set<UUID> = []
        while let current = next {
            guard seen.insert(current).inserted, let folder = lookup[current], folder.trashedAt == nil else { return false }
            if let proposed = locations[current] { next = proposed.parentID } else { next = folder.parentID }
        }
        return true
    }

    private static func hasAncestor(_ parent: UUID?, in ids: Set<UUID>, folders: [UUID: CourseFolder]) -> Bool {
        guard parent != nil, !ids.isEmpty else { return false }
        var next = parent, seen: Set<UUID> = []
        while let current = next, seen.insert(current).inserted {
            if ids.contains(current) { return true }
            next = folders[current]?.parentID
        }
        return false
    }

    private func moveLocations(_ ids: Set<UUID>, to parentID: UUID?) throws -> [LibraryItemLocation] {
        let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        guard Self.activePath(parentID, in: folderLookup) else { throw LibraryError.invalidFolder }
        let selectedFolders = folders.filter { ids.contains($0.id) && $0.trashedAt == nil }
        let selectedDocuments = documents.filter { ids.contains($0.id) && $0.trashedAt == nil }
        guard selectedFolders.count + selectedDocuments.count == ids.count,
              selectedFolders.allSatisfy({ Self.activePath($0.id, in: folderLookup) }) else { throw LibraryError.invalidSelection }
        let folderIDs = Set(selectedFolders.map(\.id))
        guard !Self.hasAncestor(parentID, in: folderIDs, folders: folderLookup) else { throw LibraryError.invalidFolder }
        return selectedFolders.filter { !Self.hasAncestor($0.parentID, in: folderIDs, folders: folderLookup) }
            .map { LibraryItemLocation(id: $0.id, isFolder: true, parentID: parentID) }
            + selectedDocuments.filter { !Self.hasAncestor($0.folderID, in: folderIDs, folders: folderLookup) }
                .map { LibraryItemLocation(id: $0.id, isFolder: false, parentID: parentID) }
    }

    private func validateLocations(_ locations: [LibraryItemLocation]) throws {
        let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let activeDocumentIDs = Set(documents.filter { $0.trashedAt == nil }.map(\.id))
        let proposed = Dictionary(uniqueKeysWithValues: locations.filter(\.isFolder).map { ($0.id, $0) })
        var conflictingIDs = Set<UUID>()
        if !proposed.isEmpty {
            let parents = Set(proposed.values.map(\.parentID))
            var siblings: [UUID?: [(id: UUID, name: String)]] = [:]
            for folder in folders where folder.trashedAt == nil {
                let parent = proposed[folder.id].map { $0.parentID } ?? folder.parentID
                guard parents.contains(parent) else { continue }
                siblings[parent, default: []].append((folder.id, folder.name.precomposedStringWithCanonicalMapping))
            }
            // Preserve sameName's comparison while checking each destination's names only once.
            for group in siblings.values {
                let sorted = group.sorted { $0.name.compare($1.name, options: .caseInsensitive) == .orderedAscending }
                for (left, right) in zip(sorted, sorted.dropFirst())
                    where left.name.compare(right.name, options: .caseInsensitive) == .orderedSame {
                    conflictingIDs.insert(left.id)
                    conflictingIDs.insert(right.id)
                }
            }
        }
        for location in locations {
            guard Self.activePath(location.parentID, in: folderLookup, locations: proposed) else { throw LibraryError.invalidFolder }
            if location.isFolder {
                guard let folder = folderLookup[location.id], folder.trashedAt == nil,
                      Self.activePath(folder.id, in: folderLookup, locations: proposed) else { throw LibraryError.invalidSelection }
                guard !conflictingIDs.contains(folder.id) else { throw LibraryError.duplicateFolderName }
            } else if !activeDocumentIDs.contains(location.id) { throw LibraryError.invalidSelection }
        }
    }

    private func applyLocations(_ locations: [LibraryItemLocation], undo: UndoManager?) throws {
        try validateLocations(locations)
        let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let documentLookup = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let old = locations.compactMap { location -> LibraryItemLocation? in
            let parent = location.isFolder ? folderLookup[location.id]!.parentID : documentLookup[location.id]!.folderID
            return parent == location.parentID ? nil : LibraryItemLocation(id: location.id, isFolder: location.isFolder, parentID: parent)
        }
        guard !old.isEmpty else { return }
        for location in locations {
            if location.isFolder { folderLookup[location.id]!.parentID = location.parentID }
            else { documentLookup[location.id]!.folderID = location.parentID }
        }
        try save()
        undo?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                do { try store.reload(); try store.applyLocations(old, undo: undo) } catch { store.error = error.localizedDescription }
            }
        }
        undo?.setActionName("항목 이동")
    }

    func canTrash(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            try validateTrashSelection(documentIDs: ids, folderIDs: ids, trashed: false)
            let selected = folders.filter { ids.contains($0.id) }
            guard !selected.isEmpty else { return true }
            let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            return selected.allSatisfy { Self.activePath($0.id, in: folderLookup) }
        } catch { return false }
    }

    func trash(documentIDs: Set<UUID>, folderIDs: Set<UUID>) throws {
        guard !documentIDs.isEmpty || !folderIDs.isEmpty else { return }
        try reload()
        try validateTrashSelection(documentIDs: documentIDs, folderIDs: folderIDs, trashed: false)
        let now = Date.now
        let selected = Set(folders.filter { folderIDs.contains($0.id) && $0.trashedAt == nil }.map(\.id))
        let folderLookup = selected.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        guard selected.allSatisfy({ Self.activePath($0, in: folderLookup) }) else { throw LibraryError.invalidFolder }
        let children = childFolders
        var groups: [UUID: UUID] = [:]
        for root in folders where selected.contains(root.id) && !Self.hasAncestor(root.parentID, in: selected, folders: folderLookup) {
            var pending = [root]
            while let folder = pending.popLast() {
                guard folder.trashedAt == nil, groups[folder.id] == nil else { continue }
                groups[folder.id] = root.id
                pending += children[folder.id] ?? []
            }
        }
        for folder in folders {
            if let group = groups[folder.id] { folder.trashedAt = now; folder.trashGroupID = group }
        }
        for item in documents where item.trashedAt == nil {
            if let parent = item.folderID, let group = groups[parent] {
                item.trashedAt = now; item.trashGroupID = group
            } else if documentIDs.contains(item.id) { item.trashedAt = now; item.trashGroupID = nil }
        }
        try save()
    }

    func restore(documentIDs: Set<UUID>, folderIDs: Set<UUID>) throws {
        guard !documentIDs.isEmpty || !folderIDs.isEmpty else { return }
        try reload()
        try validateTrashSelection(documentIDs: documentIDs, folderIDs: folderIDs, trashed: true)
        let folderLookup = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let groups = trashMembers(folderIDs: folderIDs)
        let restoredIDs = Set(groups.keys)
        let restoredDocuments = documents.filter { $0.trashedAt != nil && (documentIDs.contains($0.id) || belongsToTrashGroup($0, groups: groups)) }
        var pending = restoredIDs
        var locations: [UUID: LibraryItemLocation] = [:]
        var names: [UUID: String] = [:]
        while !pending.isEmpty {
            let ready = folders.filter { pending.contains($0.id) && !($0.parentID.map(pending.contains) ?? false) }
                .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
            guard !ready.isEmpty else { throw LibraryError.invalidFolder }
            for folder in ready {
                var parent = folder.parentID
                if let id = parent, locations[id] == nil, !Self.activePath(id, in: folderLookup) { parent = nil }
                let base = try Self.validName(folder.name)
                var name = base, suffix = 0
                while folders.contains(where: { other in
                    let target = locations[other.id].map { $0.parentID } ?? other.parentID
                    return other.id != folder.id && (other.trashedAt == nil || names[other.id] != nil)
                        && target == parent && Self.sameName(names[other.id] ?? other.name, name)
                }) {
                    suffix += 1
                    let ending = suffix == 1 ? " (복원)" : " (복원 \(suffix))"
                    name = String(base.prefix(200 - ending.count)) + ending
                }
                locations[folder.id] = LibraryItemLocation(id: folder.id, isFolder: true, parentID: parent)
                names[folder.id] = name
                pending.remove(folder.id)
            }
        }
        for folder in folders where restoredIDs.contains(folder.id) {
            folder.parentID = locations[folder.id]!.parentID
            folder.name = names[folder.id]!
            folder.trashedAt = nil
            folder.trashGroupID = nil
        }
        for item in restoredDocuments {
            item.trashedAt = nil; item.trashGroupID = nil
            if !Self.activePath(item.folderID, in: folderLookup) { item.folderID = nil }
        }
        try save()
    }

    private var childFolders: [UUID: [CourseFolder]] {
        var children: [UUID: [CourseFolder]] = [:]
        for folder in folders { if let parent = folder.parentID { children[parent, default: []].append(folder) } }
        return children
    }

    private func validateTrashSelection(documentIDs: Set<UUID>, folderIDs: Set<UUID>, trashed: Bool) throws {
        let actual = Set(documents.filter { documentIDs.contains($0.id) && ($0.trashedAt != nil) == trashed }.map(\.id))
            .union(folders.filter { folderIDs.contains($0.id) && ($0.trashedAt != nil) == trashed }.map(\.id))
        guard actual == documentIDs.union(folderIDs) else { throw LibraryError.invalidSelection }
    }

    private func trashMembers(folderIDs: Set<UUID>) -> [UUID: UUID] {
        let children = childFolders
        var groups: [UUID: UUID] = [:]
        for root in folders where folderIDs.contains(root.id) && root.trashedAt != nil {
            let group = root.trashGroupID ?? root.id
            var pending = [root]
            while let folder = pending.popLast() {
                guard folder.trashedAt != nil, groups[folder.id] == nil,
                      folder.id == root.id || folder.trashGroupID == group else { continue }
                groups[folder.id] = group
                pending += children[folder.id] ?? []
            }
        }
        return groups
    }

    private func belongsToTrashGroup(_ document: LectureDocument, groups: [UUID: UUID]) -> Bool {
        guard let parent = document.folderID, let group = document.trashGroupID else { return false }
        return groups[parent] == group
    }

    func permanentlyDelete(documentIDs: Set<UUID>, folderIDs: Set<UUID>) throws {
        guard !documentIDs.isEmpty || !folderIDs.isEmpty else { return }
        try save()
        try recoverPendingDeletions()
        try validateTrashSelection(documentIDs: documentIDs, folderIDs: folderIDs, trashed: true)
        let groups = trashMembers(folderIDs: folderIDs)
        let chosenFolders = folders.filter { groups[$0.id] != nil }
        let chosen = documents.filter { $0.trashedAt != nil && (documentIDs.contains($0.id) || belongsToTrashGroup($0, groups: groups)) }
        guard !chosen.isEmpty || !chosenFolders.isEmpty else { return }
        let chosenIDs = Set(chosen.map(\.id))
        let retainedPDFs = Set(documents.filter { !chosenIDs.contains($0.id) }.map(\.filename))
        let retainedAudio = Set(questions.filter { !chosenIDs.contains($0.documentID) }.compactMap(\.audioFilename))
        let pdfs = Set(chosen.map(\.filename)).subtracting(retainedPDFs)
        let chosenAudio = Set(questions.filter { chosenIDs.contains($0.documentID) }.compactMap(\.audioFilename))
        let audio = chosenAudio.union(chosenAudio.map(Self.recordingMetadata))
            .subtracting(retainedAudio.union(retainedAudio.map(Self.recordingMetadata)))
        let entries = try (pdfs.map { ("Documents", $0) } + audio.map { ("Recordings", $0) }).map { child, filename in
            PendingFileDeletion(directory: child, filename: filename, stagedFilename: UUID().uuidString,
                                wasPresent: FileManager.default.fileExists(atPath: try ownedURL(filename: filename, child: child).path))
        }
        let journal = try ownedFolder("Staging").appendingPathComponent("delete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        do { try JSONEncoder().encode(entries).write(to: journal.appendingPathComponent("manifest.json"), options: .atomic) }
        catch { try? FileManager.default.removeItem(at: journal); throw error }
        do {
            for entry in entries {
                let original = try ownedURL(filename: entry.filename, child: entry.directory)
                if FileManager.default.fileExists(atPath: original.path) {
                    try FileManager.default.moveItem(at: original, to: journal.appendingPathComponent(entry.stagedFilename))
                }
            }
            if !chosenIDs.isEmpty {
                for record in lookups where chosenIDs.contains(record.documentID) { context.delete(record) }
                for question in questions where chosenIDs.contains(question.documentID) { context.delete(question) }
            }
            for item in chosen { context.delete(item) }
            for folder in chosenFolders { context.delete(folder) }
            try save()
        } catch {
            context.rollback()
            try? reload()
            do { try recoverPendingDeletions() }
            catch { self.error = error.localizedDescription }
            throw error
        }
        do { try recoverPendingDeletions() }
        catch { self.error = "기록은 삭제됐지만 임시 파일 정리가 남았습니다. 다음 실행 때 다시 확인합니다: \(error.localizedDescription)" }
    }

    private func ownedURL(filename: String, child: String) throws -> URL {
        guard ["Documents", "Recordings"].contains(child), Self.singleFilename(filename) else { throw LibraryError.recoveryNeeded }
        let folder = try ownedFolder(child)
        let file = folder.appendingPathComponent(filename)
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(folder.path + "/") else { throw LibraryError.recoveryNeeded }
        return file
    }

    private func ownedFolder(_ child: String) throws -> URL {
        guard ["Documents", "Recordings", "Staging"].contains(child) else { throw LibraryError.recoveryNeeded }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let folder = root.appendingPathComponent(child)
        let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw LibraryError.recoveryNeeded }
        return folder
    }

    nonisolated private static func singleFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    nonisolated private static func recordingMetadata(_ filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent + ".json"
    }

    /// Run only at startup, before any import can own a staging file.
    private func removeAbandonedImports() throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: ownedFolder("Staging"),
                                              includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files {
            guard file.pathExtension == "pdf",
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  file.lastPathComponent == id.uuidString + ".pdf" else { continue }
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink == false else { continue }
            try fm.removeItem(at: file)
        }
    }

    private func recoverPendingDeletions() throws {
        let fm = FileManager.default
        let journals = try fm.contentsOfDirectory(at: ownedFolder("Staging"), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("delete-") }
        guard !journals.isEmpty else { return }
        // DB references decide recovery even if the app quit between save and journal cleanup.
        let pdfReferences = Set(try context.fetch(FetchDescriptor<LectureDocument>()).map(\.filename))
        let audio = Set(try context.fetch(FetchDescriptor<QuestionRecord>()).compactMap(\.audioFilename))
        let audioReferences = audio.union(audio.map(Self.recordingMetadata))
        for journal in journals {
            let properties = try journal.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else { throw LibraryError.recoveryNeeded }
            let manifest = journal.appendingPathComponent("manifest.json")
            let entries = try JSONDecoder().decode([PendingFileDeletion].self, from: Data(contentsOf: manifest))
            for entry in entries {
                let original = try ownedURL(filename: entry.filename, child: entry.directory)
                guard UUID(uuidString: entry.stagedFilename) != nil else { throw LibraryError.recoveryNeeded }
                let staged = journal.appendingPathComponent(entry.stagedFilename)
                guard (try? staged.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibraryError.recoveryNeeded }
                let referenced = (entry.directory == "Documents" ? pdfReferences : audioReferences).contains(entry.filename)
                if fm.fileExists(atPath: staged.path) {
                    if referenced {
                        guard !fm.fileExists(atPath: original.path) else { throw LibraryError.recoveryNeeded }
                        try fm.moveItem(at: staged, to: original)
                    } else { try fm.removeItem(at: staged) }
                } else if referenced, entry.wasPresent, !fm.fileExists(atPath: original.path) { throw LibraryError.recoveryNeeded }
            }
            let remaining = try fm.contentsOfDirectory(atPath: journal.path)
            guard remaining == ["manifest.json"] else { throw LibraryError.recoveryNeeded }
            try fm.removeItem(at: journal)
        }
    }

    func purgeExpired(days: Int) {
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) else { return }
        let docs = Set(documents.filter { ($0.trashedAt ?? .distantFuture) < cutoff }.map(\.id))
        let dirs = Set(folders.filter { ($0.trashedAt ?? .distantFuture) < cutoff }.map(\.id))
        guard !docs.isEmpty || !dirs.isEmpty else { return }
        do { try permanentlyDelete(documentIDs: docs, folderIDs: dirs) } catch { self.error = error.localizedDescription }
    }

    nonisolated private static func prepareImport(_ source: URL, staging: URL) throws -> PDFImport {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "pdf" else { throw LibraryError.unsupportedPDF }
        let id = UUID(), temporary = staging.appendingPathComponent(id.uuidString + ".pdf")
        do {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: temporary)
            try Task.checkCancellation()
            guard let pdf = PDFDocument(url: temporary) else { throw LibraryError.unsupportedPDF }
            guard !pdf.isLocked else { throw LibraryError.lockedPDF }
            guard pdf.pageCount > 0 else { throw LibraryError.unsupportedPDF }
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hasher.update(data: bytes) }
            return PDFImport(id: id, name: try validName(source.deletingPathExtension().lastPathComponent),
                             fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                             pageCount: pdf.pageCount, stagingURL: temporary)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    func importPDFs(_ urls: [URL], folderID: UUID?, onDuplicate: @MainActor (LectureDocument) async -> Bool,
                    onOpenExisting: @MainActor (LectureDocument) -> Void) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false; importProgress = "" }
        var failures: [String] = []
        for (index, source) in urls.enumerated() {
            if Task.isCancelled { break }
            importProgress = "교안 추가 중 · \(index + 1) / \(urls.count)"
            do {
                try requireActiveFolder(folderID)
                let staging = try ownedFolder("Staging")
                let preparation = Task.detached(priority: .userInitiated) {
                    try Self.prepareImport(source, staging: staging)
                }
                let prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                defer { try? FileManager.default.removeItem(at: prepared.stagingURL) }
                try Task.checkCancellation()
                try requireActiveFolder(folderID)
                if let duplicate = documents.first(where: { $0.fingerprint == prepared.fingerprint && $0.trashedAt == nil }),
                   !(await onDuplicate(duplicate)), documents.contains(where: { $0.id == duplicate.id && $0.trashedAt == nil }) {
                    try Task.checkCancellation(); onOpenExisting(duplicate); continue
                }
                try Task.checkCancellation()
                try requireActiveFolder(folderID)
                let item = LectureDocument(id: prepared.id, name: prepared.name, fingerprint: prepared.fingerprint,
                                           pageCount: prepared.pageCount, folderID: folderID)
                let destination = try ownedURL(filename: item.filename, child: "Documents")
                try FileManager.default.moveItem(at: prepared.stagingURL, to: destination)
                context.insert(item)
                do { try save() } catch { try? FileManager.default.removeItem(at: destination); throw error }
            } catch is CancellationError { break }
            catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func notes(for document: LectureDocument) -> [PDFWordNote] {
        lookups.filter { $0.documentID == document.id && ["word", "sentence"].contains($0.kind) }.compactMap { record in
            record.anchor.map { PDFWordNote(anchor: $0, meaning: record.shortText, colorHex: record.annotationColorHex) }
        }
    }

    func lookup(documentID: UUID, anchor: PDFAnchor) -> LookupRecord? {
        lookups.first {
            guard $0.documentID == documentID, $0.pageIndex == anchor.pageIndex, $0.text == anchor.text,
                  let stored = $0.anchor else { return false }
            return stored.pageIndex == anchor.pageIndex && stored.text == anchor.text && stored.rects == anchor.rects
        }
    }

    func record(document: LectureDocument, anchor: PDFAnchor, kind: String, answer: TranslationAnswer,
                provider: String, model: String, annotationColorHex: String = AnnotationColor.defaultHex) throws {
        guard document.trashedAt == nil, documents.contains(where: { $0.id == document.id }) else { return }
        if let old = lookup(documentID: document.id, anchor: anchor) {
            old.anchorData = try JSONEncoder().encode(anchor)
            old.shortText = answer.shortText; old.explanation = answer.explanation
            old.provider = provider; old.model = model; old.kind = kind; old.createdAt = .now
        } else {
            context.insert(try LookupRecord(documentID: document.id, anchor: anchor, kind: kind,
                                            answer: answer, provider: provider, model: model, annotationColorHex: annotationColorHex))
        }
        try save()
    }

    func updateAnnotationColor(_ record: LookupRecord, hex: String) throws {
        guard let color = AnnotationColor.normalizedHex(hex) else { throw AnnotationColorError.invalidHex }
        guard let existing = lookups.first(where: { $0.id == record.id }) else { throw LibraryError.invalidSelection }
        guard existing.annotationColorHex != color else { return }
        existing.annotationColorHex = color
        try saveChanges()
    }

    func addQuestion(document: LectureDocument, text: String, rawText: String = "") throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, document.trashedAt == nil,
              documents.contains(where: { $0.id == document.id }) else { return }
        context.insert(QuestionRecord(documentID: document.id, text: text, rawText: rawText)); try save()
    }
}
