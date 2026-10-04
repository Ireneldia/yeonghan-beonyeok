import Foundation
import SwiftData

@Model final class CourseFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var trashedAt: Date?
    var parentID: UUID? = nil
    var trashGroupID: UUID? = nil
    init(name: String, parentID: UUID? = nil) {
        id = UUID(); self.name = name; self.parentID = parentID; createdAt = .now
    }
}

@Model final class LectureDocument {
    @Attribute(.unique) var id: UUID
    var name: String
    var filename: String
    var fingerprint: String
    var pageCount: Int
    var folderID: UUID?
    var createdAt: Date
    var lastPage: Int
    var trashedAt: Date?
    var trashGroupID: UUID?

    init(id: UUID, name: String, fingerprint: String, pageCount: Int, folderID: UUID?) {
        self.id = id; self.name = name; self.filename = id.uuidString + ".pdf"
        self.fingerprint = fingerprint; self.pageCount = pageCount; self.folderID = folderID
        self.createdAt = .now; self.lastPage = 0
    }
}

@Model final class LookupRecord {
    @Attribute(.unique) var id: UUID
    var documentID: UUID
    var anchorData: Data
    var text: String
    var pageIndex: Int
    var kind: String
    var shortText: String
    var explanation: String
    var provider: String
    var model: String
    var createdAt: Date
    var annotationColorHex: String = AnnotationColor.defaultHex

    init(documentID: UUID, anchor: PDFAnchor, kind: String, answer: TranslationAnswer,
         provider: String, model: String, annotationColorHex: String = AnnotationColor.defaultHex) throws {
        guard let color = AnnotationColor.normalizedHex(annotationColorHex) else { throw AnnotationColorError.invalidHex }
        id = UUID(); self.documentID = documentID; anchorData = try JSONEncoder().encode(anchor)
        text = anchor.text; pageIndex = anchor.pageIndex; self.kind = kind
        shortText = answer.shortText; explanation = answer.explanation
        self.provider = provider; self.model = model; createdAt = .now
        self.annotationColorHex = color
    }

    var anchor: PDFAnchor? { try? JSONDecoder().decode(PDFAnchor.self, from: anchorData) }
}

@Model final class QuestionRecord {
    @Attribute(.unique) var id: UUID
    var documentID: UUID
    var text: String
    var rawText: String
    var createdAt: Date
    var audioFilename: String?
    init(documentID: UUID, text: String, rawText: String = "") {
        id = UUID(); self.documentID = documentID; self.text = text; self.rawText = rawText
        createdAt = .now
    }
}
