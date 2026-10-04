import AppKit
import SwiftUI
import SwiftData
import PDFKit
import Observation

@Observable @MainActor
final class AppSession {
    let library: LibraryStore
    let preferences = AppPreferences()
    let translation = TranslationService()
    let setup = OllamaSetupController()
    let localModels = LocalModelStore()
    let speech = SpeechController()
    var documentID: UUID?
    var selectedAnchor: PDFAnchor?
    var selectedAnswer: TranslationAnswer?
    var translationError: String?
    var isTranslating = false
    var showingImporter = false
    var showingModels = false
    var incomingURLs: [URL] = []
    private var translationTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var correctionTasks: [UUID: Task<Void, Never>] = [:]
    private let pageText = NSCache<NSString, NSString>()
    private var generation = UUID()

    init(library: LibraryStore) { self.library = library; pageText.countLimit = 24 }
    var document: LectureDocument? { library.documents.first { $0.id == documentID && $0.trashedAt == nil } }

    func open(_ document: LectureDocument) {
        closeReader(); documentID = document.id; prepareSelectedModel()
    }

    func prepareSelectedModel() {
        preparationTask?.cancel()
        guard document != nil, translation.configuration.provider == .local,
              !(preferences.respectLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled) else { return }
        preparationTask = Task { await translation.prepareLocalModelIfNeeded() }
    }

    func closeReader() {
        generation = UUID()
        translationTask?.cancel(); translationTask = nil
        preparationTask?.cancel(); preparationTask = nil
        for task in correctionTasks.values { task.cancel() }; correctionTasks.removeAll()
        translation.cancelAll(); speech.cancel()
        documentID = nil; selectedAnchor = nil; selectedAnswer = nil; translationError = nil; isTranslating = false
        pageText.removeAllObjects()
        do { try library.save() } catch { library.error = error.localizedDescription }
    }

    func quit() async {
        let translationShutdown = translation.beginShutdown()
        closeReader(); localModels.cancelAllDownloads()
        await speech.shutdown()
        await speech.models.cancelDownloadAndWait()
        await translationShutdown.value
    }

    func deleteLookup(_ record: LookupRecord) throws {
        guard library.lookups.contains(where: { $0.id == record.id }) else { return }
        let isSelected = documentID == record.documentID && selectedAnchor.map {
            library.lookup(documentID: record.documentID, anchor: $0)?.id == record.id
        } == true
        library.context.delete(record)
        try library.save()
        if isSelected {
            generation = UUID()
            translationTask?.cancel(); translationTask = nil
            selectedAnchor = nil; selectedAnswer = nil; translationError = nil; isTranslating = false
        }
    }

    func deleteQuestion(_ record: QuestionRecord) throws {
        let id = record.id
        guard library.questions.contains(where: { $0.id == id }) else { return }
        library.context.delete(record)
        try library.save()
        correctionTasks.removeValue(forKey: id)?.cancel()
    }

    func select(_ anchor: PDFAnchor, refresh: Bool = false, sentence: Bool? = nil) {
        guard let document else { return }
        let record = library.lookup(documentID: document.id, anchor: anchor)
        let anchor = PDFAnchor(pageIndex: anchor.pageIndex, text: anchor.text, rects: anchor.rects,
                               isSentence: sentence ?? (refresh ? anchor.isSentence : record?.anchor?.isSentence ?? anchor.isSentence))
        translationTask?.cancel()
        generation = UUID(); let token = generation
        selectedAnchor = anchor; selectedAnswer = nil; translationError = nil; isTranslating = false
        if !refresh, let record, record.anchor?.isSentence == anchor.isSentence {
            selectedAnswer = TranslationAnswer(shortText: record.shortText, explanation: record.explanation)
            return
        }
        let id = document.id, configuration = translation.configuration
        let annotationColor = preferences.annotationColorHex
        let file = library.url(for: document), cacheKey = "\(id)-\(anchor.pageIndex)" as NSString
        let cachedText = pageText.object(forKey: cacheKey) as String?
        let kind: TranslationRequest.Kind = anchor.isSentence ? .sentence : .word
        let subject = document.folderID.map { library.folderPath($0) } ?? "컴퓨터공학"
        isTranslating = true
        translationTask = Task {
            do {
                let context: String
                if let cachedText { context = cachedText }
                else {
                    context = await Task.detached {
                        autoreleasepool { PDFDocument(url: file)?.page(at: anchor.pageIndex)?.string ?? "" }
                    }.value
                    try Task.checkCancellation()
                    pageText.setObject(context as NSString, forKey: cacheKey)
                }
                guard generation == token else { return }
                let request = TranslationRequest(text: anchor.text, pageText: context, subject: subject, kind: kind)
                let answer = try await translation.translate(request, using: configuration)
                try Task.checkCancellation()
                guard generation == token, self.documentID == id, document.trashedAt == nil else { return }
                try library.record(document: document, anchor: anchor, kind: kind == .word ? "word" : "sentence", answer: answer,
                                   provider: configuration.provider.rawValue, model: configuration.selected.model,
                                   annotationColorHex: annotationColor)
                selectedAnswer = answer; isTranslating = false
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == token, self.documentID == id else { return }
                translationError = error.localizedDescription; isTranslating = false
            }
        }
    }

    func toggleSpeech(_ purpose: SpeechMode) async {
        if speech.mode != .idle { await speech.stop(); return }
        guard let document else { return }
        let id = document.id, page = document.lastPage, configuration = translation.configuration
        await speech.start(mode: purpose, documentID: id, documentURL: library.url(for: document), pageIndex: page) { [weak self] text in
            guard let self, self.documentID == id, document.trashedAt == nil else { return }
            if purpose == .question {
                self.saveSpokenQuestion(text, document: document, configuration: configuration, terms: self.speech.correctionTerms)
            } else { self.findSpokenText(text, document: document, pageIndex: document.lastPage) }
        }
    }

    func retryLastQuestion() async {
        guard speech.lastRecordingPurpose == .question else { return }
        guard let id = speech.lastRecordingDocumentID,
              let document = library.documents.first(where: { $0.id == id && $0.trashedAt == nil }) else {
            library.error = "녹음과 연결된 교안을 먼저 복구하거나 열어주세요."; return
        }
        let configuration = translation.configuration
        await speech.retryLastRecording { [weak self] text in
            guard let self, document.trashedAt == nil else { return }
            self.saveSpokenQuestion(text, document: document, configuration: configuration, terms: self.speech.correctionTerms)
        }
    }

    private func saveSpokenQuestion(_ text: String, document: LectureDocument, configuration: TranslationConfiguration, terms: [String]) {
        do {
            let record = QuestionRecord(documentID: document.id, text: text, rawText: text)
            record.audioFilename = speech.lastRecordingURL?.lastPathComponent
            library.context.insert(record); try library.save()
            let subject = document.folderID.map { library.folderPath($0) } ?? "컴퓨터공학"
            let id = record.id
            correctionTasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { self.correctionTasks.removeValue(forKey: id) }
                do {
                    let fixed = try await self.translation.correctTranscript(text, terms: terms, subject: subject, using: configuration)
                    try Task.checkCancellation()
                    guard document.trashedAt == nil, self.library.questions.contains(where: { $0.id == id }) else { return }
                    record.text = fixed; try self.library.save()
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.library.error = "질문 원문은 저장했습니다. 교정: \(error.localizedDescription)" } }
            }
        } catch { library.error = error.localizedDescription }
    }

    private func findSpokenText(_ text: String, document: LectureDocument, pageIndex: Int) {
        guard let pdf = PDFDocument(url: library.url(for: document)), let page = pdf.page(at: pageIndex), let content = page.string else { return }
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sentence punctuation can be supplied by ASR; leading dots and trailing +/# belong to terms.
        while let last = query.last, ".,!?…。！？".contains(last) { query.removeLast() }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let leading = #"(?<![\p{L}\p{M}\p{N}_+#.])"#
        let trailing = #"(?![\p{L}\p{M}\p{N}_+#])"#
        let boundary = try? NSRegularExpression(pattern: leading + #"[\s\S]+"# + trailing)
        let source = content as NSString
        var remaining = NSRange(location: 0, length: source.length)
        var range = NSRange(location: NSNotFound, length: 0)
        // Retain the literal search's diacritic handling, but reject matches inside another token.
        while remaining.length > 0 {
            let candidate = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard candidate.location != NSNotFound else { break }
            if boundary?.firstMatch(in: content, options: [.anchored, .withTransparentBounds], range: candidate)?.range == candidate {
                range = candidate; break
            }
            let next = NSMaxRange(candidate)
            remaining = NSRange(location: next, length: source.length - next)
        }
        if range.location == NSNotFound {
            let pattern = query.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
            let expression = try? NSRegularExpression(pattern: leading + pattern + trailing, options: .caseInsensitive)
            range = expression?.firstMatch(in: content, range: NSRange(location: 0, length: source.length))?.range ?? range
        }
        guard range.location != NSNotFound, let selection = page.selection(for: range) else {
            translationError = "현재 페이지에서 ‘\(query)’을 찾지 못했습니다. 단어를 직접 선택할 수 있습니다."
            return
        }
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        guard !rects.isEmpty else { return }
        select(PDFAnchor(pageIndex: pageIndex, text: selection.string ?? query, rects: rects, isSentence: false))
    }
}

final class NativeAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: AppSession?
    private var isQuitting = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        if !isQuitting {
            isQuitting = true
            Task {
                await session.quit()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
