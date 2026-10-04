import Foundation

enum LibraryLocation: Hashable { case library, folder(UUID), trash, trashFolder(UUID), vocabulary, questions }

struct LibraryEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let isFolder: Bool
    var createdAt: Date? = nil
    var pageCount: Int? = nil

    var kind: String { isFolder ? "폴더" : "PDF 교안" }
}

enum LibrarySort: String, CaseIterable {
    case name, dateAdded, kind, pageCount

    var title: String {
        switch self {
        case .name: "이름"
        case .dateAdded: "추가일"
        case .kind: "종류"
        case .pageCount: "페이지"
        }
    }
    var defaultAscending: Bool { self == .name || self == .kind }

    func ordered(_ entries: [LibraryEntry], ascending: Bool) -> [LibraryEntry] {
        entries.sorted { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            let comparison: ComparisonResult
            switch self {
            case .name: comparison = left.title.localizedStandardCompare(right.title)
            case .dateAdded: comparison = (left.createdAt ?? .distantPast).compare(right.createdAt ?? .distantPast)
            case .kind: comparison = left.kind.localizedStandardCompare(right.kind)
            case .pageCount:
                let a = left.pageCount ?? 0, b = right.pageCount ?? 0
                comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            }
            if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            let name = left.title.localizedStandardCompare(right.title)
            if name != .orderedSame { return name == .orderedAscending }
            return left.id.uuidString < right.id.uuidString
        }
    }
}
