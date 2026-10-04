import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var session: AppSession
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @State private var location = LibraryLocation.library
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @AppStorage("library.listMode") private var listMode = false
    @AppStorage("library.iconSize") private var iconSize = 64.0
    @AppStorage("library.sortKey") private var librarySort: LibrarySort = .name
    @AppStorage("library.sortAscending") private var sortAscending = true
    @State private var libraryRenamingID: UUID?
    @State private var sidebarRenamingID: UUID?
    @State private var deletingIDs = Set<UUID>()
    @State private var showingDelete = false
    @State private var emptyingTrash = false
    @State private var duplicateName = ""
    @State private var duplicateReply: CheckedContinuation<Bool, Never>?
    @State private var inspectorTab = 0
    @State private var questionDraft = ""
    @State private var navigationAnchor: PDFAnchor?
    @State private var navigationRequestID = 0
    @State private var isExporting = false
    @State private var windowVisible = true
    @State private var modelTab = 0
    @AppStorage("library.showsSidebar") private var showsSidebar = true

    private var library: LibraryStore { session.library }
    private var activeFolders: [CourseFolder] { library.folders.filter { $0.trashedAt == nil } }
    private var isTrash: Bool {
        if case .trash = location { return true }
        if case .trashFolder = location { return true }
        return false
    }
    private var currentFolder: UUID? { if case .folder(let id) = location { return id }; return nil }
    private var title: String {
        if let document = session.document { return document.name }
        switch location {
        case .library: return "서재"
        case .vocabulary: return "단어장"
        case .questions: return "질문"
        case .trash: return "휴지통"
        case .folder(let id), .trashFolder(let id): return library.folders.first { $0.id == id }?.name ?? "폴더"
        }
    }

    var body: some View {
        NativeSidebarSplit(isVisible: $showsSidebar) { sidebar } detail: {
            VStack(spacing: 0) {
                if let document = session.document { reader(document) }
                else if location == .vocabulary { vocabulary }
                else if location == .questions { questionLibrary }
                else { libraryContents }
                if library.isImporting {
                    Divider()
                    HStack { ProgressView().controlSize(.small); Text(library.importProgress).font(.caption); Spacer() }
                        .padding(10).background(.bar)
                }
            }

        }
        .navigationTitle(title)
        .background(windowToolbar.frame(width: 0, height: 0))
        .frame(minWidth: 980, minHeight: 600)
        .background(WindowLifecycle(onClose: { windowVisible = false; finishDuplicate(copy: false); session.closeReader() }))
        .containerBackground(.regularMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .preferredColorScheme(session.preferences.colorScheme)
        .onAppear { windowVisible = true; library.purgeExpired(days: session.preferences.trashRetentionDays) }
        .onChange(of: session.preferences.trashRetentionDays) { _, days in library.purgeExpired(days: days) }
        .onChange(of: session.translation.configuration.provider) { _, _ in session.prepareSelectedModel() }
        .onChange(of: session.translation.configuration.local.model) { _, _ in session.prepareSelectedModel() }
        .onChange(of: location) { _, _ in
            if session.documentID != nil { session.closeReader() }
            selection = []; navigationAnchor = nil; libraryRenamingID = nil
        }
        .onChange(of: search) { _, query in
            guard session.documentID != nil, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.closeReader()
        }
        .onChange(of: session.documentID) { _, id in questionDraft = ""; inspectorTab = location == .questions ? 2 : 0; if id == nil { navigationAnchor = nil } }
        .onChange(of: session.selectedAnchor) { _, anchor in if let anchor { inspectorTab = anchor.isSentence ? 1 : 0 } }
        .sheet(isPresented: $session.showingImporter, onDismiss: { session.incomingURLs = [] }) {
            PDFImportSheet(folders: activeFolders, folderPaths: library.folderPaths,
                           initialURLs: session.incomingURLs,
                           initialFolder: currentFolder) { urls, folder in
                session.showingImporter = false
                Task { await importFiles(urls, folder: folder) }
            }
        }
        .sheet(isPresented: $session.showingModels) {
            VStack(spacing: 0) {
                Picker("모델 관리", selection: $modelTab) {
                    Text("번역 연결").tag(0)
                    Text("로컬 모델").tag(1)
                    Text("음성 인식").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 440).padding(.top, 20).padding(.bottom, 8)
                Group {
                    switch modelTab {
                    case 1: LocalModelsView(store: session.localModels)
                    case 2: Form { SpeechSettingsView(controller: session.speech) }.formStyle(.grouped).scrollContentBackground(.hidden)
                    default: TranslationSettingsView(service: session.translation, setup: session.setup)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack { Spacer(); Button("완료") { session.showingModels = false }.keyboardShortcut(.defaultAction) }.padding()
            }.frame(width: 700, height: 720)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(get: { !session.preferences.setupComplete }, set: { if !$0 { session.preferences.setupComplete = true } })) {
            SetupWizardView(controller: session.setup, translation: session.translation) { provider in
                if let provider, let selected = TranslationProvider(rawValue: provider) { session.translation.configuration.provider = selected }
                session.preferences.setupComplete = true
            }
        }
        .alert("이미 있는 교안입니다", isPresented: Binding(get: { duplicateReply != nil }, set: { _ in })) {
            Button("기존 교안 열기", role: .cancel) { finishDuplicate(copy: false) }
            Button("복사본 추가") { finishDuplicate(copy: true) }
        } message: { Text("\(duplicateName)은(는) 이미 서재에 있습니다.") }
        .alert("작업을 완료할 수 없습니다", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("확인", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .confirmationDialog(emptyingTrash ? "휴지통을 비울까요?" : "선택한 항목을 영구적으로 삭제할까요?", isPresented: $showingDelete, titleVisibility: .visible) {
            Button(emptyingTrash ? "휴지통 비우기" : "영구 삭제", role: .destructive) {
                perform {
                    try library.permanentlyDelete(documentIDs: deletingIDs, folderIDs: deletingIDs)
                    if case .trashFolder(let id) = location, !library.folders.contains(where: { $0.id == id }) { location = .trash }
                    selection = []
                }
            }
        } message: { Text("하위 폴더와 교안, 저장된 뜻풀이·질문이 함께 삭제됩니다. 되돌릴 수 없습니다.") }
    }

    private var sidebar: some View {
        NativeLibrarySidebar(location: $location, renamingID: $sidebarRenamingID, folders: activeFolders,
            onOpen: { target in location = target; returnToSelectedLocation(target) },
            onRename: commitRename, onMenu: folderMenu, onTrashMenu: trashMenu,
            onMove: { moveEntries($0, to: $1) }, onCanMove: { library.canMove($0, to: $1) },
            onCanTrash: { library.canTrash($0) }, onTrash: trashEntries,
            onDropFiles: { urls, folder in Task { await importFiles(urls, folder: folder) } })
        .safeAreaInset(edge: .bottom) {
            Button { session.showingModels = true } label: {
                HStack {
                    ProviderLogo(provider: session.translation.configuration.provider).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.translation.configuration.provider.title).font(.caption.bold())
                        Text(session.translation.selectedModelLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain).help("번역 연결과 모델 선택")
        }
    }

    private var windowToolbar: NativeLibraryToolbar {
        let reading = session.document != nil
        let vocabulary = location == .vocabulary
        let collection = vocabulary || location == .questions
        var showsBack = reading
        if case .trashFolder = location { showsBack = true }
        if case .folder = location { showsBack = true }
        return NativeLibraryToolbar(listMode: $listMode, sort: $librarySort, ascending: $sortAscending, search: $search,
            showsBack: showsBack, showsLibraryControls: !reading && !collection,
            allowsNewFolder: !reading && !collection && !isTrash,
            exportTitle: reading ? "주석 PDF 내보내기" : vocabulary ? "Anki 내보내기" : nil,
            allowsExport: !isExporting && (reading || vocabulary && !wordRecords.isEmpty), allowsImport: !library.isImporting,
            onBack: navigateToParent,
            onNewFolder: newFolder, onImport: { session.showingImporter = true },
            onExport: { window in if let document = session.document { exportPDF(document, in: window) } else { exportAnki(in: window) } },
            onSettings: { openSettings() })
    }

    private var entries: [LibraryEntry] {
        let folderLookup = Dictionary(uniqueKeysWithValues: library.folders.map { ($0.id, $0) })
        func hasTrashParent(_ parentID: UUID?, group: UUID?) -> Bool {
            guard let parentID, let group, let parent = folderLookup[parentID], parent.trashedAt != nil else { return false }
            return (parent.trashGroupID ?? parent.id) == group
        }
        let folders: [CourseFolder]
        let documents: [LectureDocument]
        let activeIDs = Set(activeFolders.map(\.id))
        switch location {
        case .library:
            folders = activeFolders.filter { $0.parentID.map(activeIDs.contains) != true || !search.isEmpty }
            documents = library.documents.filter { $0.trashedAt == nil && ($0.folderID.map(activeIDs.contains) != true || !search.isEmpty) }
        case .folder(let id):
            let scope = library.descendantFolderIDs(of: [id])
            folders = activeFolders.filter { search.isEmpty ? $0.parentID == id : $0.id != id && scope.contains($0.id) }
            documents = library.documents.filter { $0.trashedAt == nil && (search.isEmpty ? $0.folderID == id : $0.folderID.map(scope.contains) == true) }
        case .trash:
            folders = library.folders.filter { $0.trashedAt != nil && (!hasTrashParent($0.parentID, group: $0.trashGroupID) || !search.isEmpty) }
            documents = library.documents.filter { $0.trashedAt != nil && (!hasTrashParent($0.folderID, group: $0.trashGroupID) || !search.isEmpty) }
        case .trashFolder(let id):
            let group = folderLookup[id]?.trashGroupID ?? id
            folders = library.folders.filter { $0.parentID == id && $0.trashedAt != nil && $0.trashGroupID == group }
            documents = library.documents.filter { $0.folderID == id && $0.trashedAt != nil && $0.trashGroupID == group }
        case .vocabulary, .questions: folders = []; documents = []
        }
        var counts: [UUID: Int] = [:]
        func countChild(parentID: UUID?, trashed: Bool, group: UUID?) {
            guard let parentID, let parent = folderLookup[parentID], (parent.trashedAt != nil) == trashed,
                  !trashed || group == (parent.trashGroupID ?? parent.id) else { return }
            counts[parentID, default: 0] += 1
        }
        for folder in library.folders { countChild(parentID: folder.parentID, trashed: folder.trashedAt != nil, group: folder.trashGroupID) }
        for document in library.documents { countChild(parentID: document.folderID, trashed: document.trashedAt != nil, group: document.trashGroupID) }
        let entries = folders.map { folderEntry($0, count: counts[$0.id, default: 0]) } + documents.map {
            LibraryEntry(id: $0.id, title: $0.name, subtitle: "\($0.pageCount)페이지", isFolder: false,
                         createdAt: $0.createdAt, pageCount: $0.pageCount)
        }
        return librarySort.ordered(entries.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }, ascending: sortAscending)
    }

    private func folderEntry(_ folder: CourseFolder, count: Int = 0) -> LibraryEntry {
        return LibraryEntry(id: folder.id, title: folder.name, subtitle: "\(count)개 항목",
                            isFolder: true, createdAt: folder.createdAt)
    }

    private var libraryContents: some View {
        let visibleEntries = entries
        return VStack(spacing: 0) {
            NativeLibraryView(entries: visibleEntries, selection: $selection, renamingID: $libraryRenamingID, listMode: listMode, sort: $librarySort,
                              ascending: $sortAscending, iconSize: iconSize,
                              currentFolderID: currentFolder, allowsRenaming: !isTrash, allowsFileDrops: !isTrash,
                              onOpen: openEntry, onRename: commitRename,
                              onMenu: { menu($0, $1) }, onBackgroundMenu: backgroundMenu, onDropFiles: { urls, folder in
                                  let destination = folder ?? currentFolder
                                  Task { await importFiles(urls, folder: destination) }
                              },
                              onCanMove: { ids, folder in !isTrash && library.canMove(ids, to: folder) },
                              onMove: { ids, folder in !isTrash && moveEntries(ids, to: folder) },
                              onDelete: { ids in isTrash ? requestDelete(ids) : trash(ids) })
                .overlay {
                    if visibleEntries.isEmpty {
                        ContentUnavailableView(search.isEmpty ? (isTrash ? "휴지통이 비어 있습니다" : "교안을 추가하세요") : "검색 결과가 없습니다",
                                               systemImage: isTrash ? "trash" : "doc.badge.plus",
                                               description: Text(search.isEmpty && !isTrash ? "PDF를 이곳으로 드래그하거나 + 버튼으로 추가하세요." : ""))
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text(selection.isEmpty ? "\(visibleEntries.count)개 항목" : "\(selection.count)/\(visibleEntries.count)개 선택됨")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !listMode {
                    Slider(value: $iconSize, in: 32...128)
                        .controlSize(.small).frame(width: 128)
                        .accessibilityLabel("서재 아이콘 크기")
                        .help("아이콘 크기")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func reader(_ document: LectureDocument) -> some View {
        HSplitView {
            NativePDFReader(url: library.url(for: document), notes: library.notes(for: document), initialPage: document.lastPage,
                            navigationAnchor: navigationAnchor, navigationRequestID: navigationRequestID, onSelection: { anchor in
                                guard session.documentID == document.id, document.trashedAt == nil else { return }
                                session.select(anchor)
                            },
                            onPageChanged: { page in
                                guard session.documentID == document.id, document.trashedAt == nil, document.lastPage != page else { return }
                                perform { try library.saveReadingPosition(document: document, page: page) }
                            }).frame(minWidth: 450)
            inspector(document).frame(minWidth: 275, idealWidth: 320, maxWidth: 420)
        }
    }

    private func inspector(_ document: LectureDocument) -> some View {
        VStack(spacing: 0) {
            Picker("학습 기록", selection: $inspectorTab) {
                Text("단어").tag(0); Text("문장").tag(1); Text("질문").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if inspectorTab == 2 { questions(document) }
                    else {
                        if let anchor = session.selectedAnchor, anchor.isSentence == (inspectorTab == 1) { meaning }
                        savedLookups(document, kind: inspectorTab == 0 ? "word" : "sentence")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(session.speech.activeMode == .read ? "읽기 중지" : "영어 읽기", systemImage: "mic") {
                        Task { await session.toggleSpeech(.read) }
                    }
                    Button(session.speech.activeMode == .question ? "질문 중지" : "질문 받아쓰기", systemImage: "waveform") {
                        inspectorTab = 2; Task { await session.toggleSpeech(.question) }
                    }
                }.controlSize(.small)
                if session.speech.mode == .preparing || session.speech.mode == .transcribing { ProgressView().controlSize(.small) }
                if !session.speech.partialText.isEmpty { Text(session.speech.partialText).font(.caption).textSelection(.enabled) }
                if let error = session.speech.error { Text(error).font(.caption).foregroundStyle(.red) }
                if session.speech.lastRecordingPurpose == .question && session.speech.lastRecordingURL != nil && session.speech.mode == .idle {
                    Button("마지막 질문 다시 인식") { Task { await session.retryLastQuestion() } }.controlSize(.small)
                }
            }.padding(12)
        }
    }

    @ViewBuilder private var meaning: some View {
        if let anchor = session.selectedAnchor {
            Text(anchor.text).font(.headline).textSelection(.enabled)
            Text("\(anchor.pageIndex + 1)페이지").font(.caption).foregroundStyle(.secondary)
            Picker("번역 방식", selection: Binding(get: { anchor.isSentence }, set: { session.select(anchor, sentence: $0) })) {
                Text("단어·표현").tag(false)
                Text("문장").tag(true)
            }.pickerStyle(.segmented)
            if session.isTranslating { HStack { ProgressView().controlSize(.small); Text("뜻풀이 중…").foregroundStyle(.secondary) } }
            if let answer = session.selectedAnswer {
                Text(answer.shortText).font(.title3.bold()).textSelection(.enabled)
                if !answer.explanation.isEmpty { Text(answer.explanation).textSelection(.enabled) }
            }
            if let error = session.translationError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("다시 풀이") { session.select(anchor, refresh: true) }.disabled(session.isTranslating)
                if let document = session.document, let record = library.lookup(documentID: document.id, anchor: anchor) {
                    Button("삭제", systemImage: "trash", role: .destructive) { deleteLookup(record) }
                }
            }
            if let document = session.document, let record = library.lookup(documentID: document.id, anchor: anchor) {
                ColorPicker("주석 색상", selection: Binding(get: {
                    Color(nsColor: (AnnotationColor(hex: record.annotationColorHex) ?? .defaultColor).nsColor)
                }, set: { color in
                    guard let hex = AnnotationColor.hex(from: NSColor(color)) else { return }
                    perform { try library.updateAnnotationColor(record, hex: hex) }
                }), supportsOpacity: false)
            }
            if session.selectedAnswer != nil { Text("이 교안의 학습 기록에 저장됩니다.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func questions(_ document: LectureDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("질문 남기기").font(.headline)
            TextEditor(text: $questionDraft).font(.body).frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator)).accessibilityLabel("교안에 대한 질문")
            Button("질문 저장") { perform { try library.addQuestion(document: document, text: questionDraft); questionDraft = "" } }
                .disabled(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(library.questions.filter { $0.documentID == document.id }) { question in
                questionRow(question)
                Divider()
            }
        }
    }

    private func questionRow(_ question: QuestionRecord, document: LectureDocument? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(question.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let document {
                    Button(document.name, systemImage: "doc") { session.open(document); inspectorTab = 2 }
                        .buttonStyle(.borderless).font(.caption).help("교안 열기")
                }
                Text(question.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                if !question.rawText.isEmpty && question.rawText != question.text {
                    DisclosureGroup("받아쓴 원문") { Text(question.rawText).font(.caption).textSelection(.enabled) }
                }
            }
            Button("질문 삭제", systemImage: "trash", role: .destructive) { deleteQuestion(question) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("질문 삭제")
        }
        .contextMenu { Button("삭제", role: .destructive) { deleteQuestion(question) } }
    }

    private var questionLibrary: some View {
        let documents = Dictionary(uniqueKeysWithValues: library.documents.filter { $0.trashedAt == nil }.map { ($0.id, $0) })
        let records = library.questions.filter {
            guard let document = documents[$0.documentID] else { return false }
            return search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                || $0.rawText.localizedCaseInsensitiveContains(search) || document.name.localizedCaseInsensitiveContains(search)
        }
        return List(records) { question in questionRow(question, document: documents[question.documentID]).padding(.vertical, 6) }
            .listStyle(.inset).alternatingRowBackgrounds(.disabled).scrollContentBackground(.hidden)
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "저장된 질문이 없습니다" : "검색 결과가 없습니다", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("교안에서 저장한 질문을 이곳에 모읍니다.")).allowsHitTesting(false)
                }
            }
    }

    private func savedLookups(_ document: LectureDocument, kind: String) -> some View {
        let selectedID = session.selectedAnchor.flatMap {
            $0.isSentence == (kind == "sentence") ? library.lookup(documentID: document.id, anchor: $0)?.id : nil
        }
        let records = library.lookups.filter { $0.documentID == document.id && $0.kind == kind && $0.id != selectedID }
        return VStack(alignment: .leading, spacing: 14) {
            if records.isEmpty, session.selectedAnchor?.isSentence != (kind == "sentence") {
                Text(kind == "word" ? "단어를 클릭하면 뜻풀이가 여기에 저장됩니다." : "문장을 드래그하면 번역이 여기에 저장됩니다.").foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                HStack(alignment: .top) {
                    Button { openLookup(record) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.text).font(.headline).lineLimit(3)
                        Text(record.shortText).foregroundStyle(.secondary)
                        if !record.explanation.isEmpty { Text(record.explanation).font(.callout).foregroundStyle(.secondary) }
                        Text("\(record.pageIndex + 1)페이지 · \(record.model)").font(.caption2).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button("삭제", systemImage: "trash", role: .destructive) { deleteLookup(record) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("\(record.text) 삭제")
                }
                .contextMenu { Button("삭제", role: .destructive) { deleteLookup(record) } }
                Divider()
            }
        }
    }

    private var wordRecords: [LookupRecord] {
        let active = Set(library.documents.filter { $0.trashedAt == nil }.map(\.id))
        return library.lookups.filter { $0.kind == "word" && active.contains($0.documentID)
            && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.shortText.localizedCaseInsensitiveContains(search)) }
    }
    private var vocabulary: some View {
        let records = wordRecords
        let names = Dictionary(uniqueKeysWithValues: library.documents.map { ($0.id, $0.name) })
        return List(records) { record in
            Button { openLookup(record) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(record.text).font(.headline).frame(minWidth: 120, maxWidth: 220, alignment: .leading)
                    Text(record.shortText).frame(maxWidth: .infinity, alignment: .leading)
                    Text(names[record.documentID] ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 6).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu { Button("삭제", role: .destructive) { deleteLookup(record) } }
        }
        .listStyle(.inset).alternatingRowBackgrounds(.disabled).scrollContentBackground(.hidden)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView(search.isEmpty ? "저장된 단어가 없습니다" : "검색 결과가 없습니다",
                                       systemImage: "character.book.closed",
                                       description: Text(search.isEmpty ? "교안에서 단어를 선택하면 이곳에 모입니다." : "다른 검색어를 입력해 보세요.")).allowsHitTesting(false)
            }
        }
    }

    private func returnToSelectedLocation(_ target: LibraryLocation) {
        guard location == target, session.documentID != nil else { return }
        session.closeReader(); selection = []; navigationAnchor = nil
    }
    private func openEntry(_ id: UUID) {
        if let folder = library.folders.first(where: { $0.id == id }) { location = folder.trashedAt == nil ? .folder(id) : .trashFolder(id) }
        else if let document = library.documents.first(where: { $0.id == id && $0.trashedAt == nil }) { navigationAnchor = nil; session.open(document) }
    }
    private func openLookup(_ record: LookupRecord) {
        guard let document = library.documents.first(where: { $0.id == record.documentID && $0.trashedAt == nil }), let anchor = record.anchor else { return }
        if session.documentID != document.id { session.open(document) }
        session.select(anchor)
        navigationAnchor = anchor; navigationRequestID += 1
    }
    private func menu(_ entry: LibraryEntry, _ ids: Set<UUID>, inSidebar: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let trashed = entry.isFolder
            ? library.folders.first { $0.id == entry.id }?.trashedAt != nil
            : library.documents.first { $0.id == entry.id }?.trashedAt != nil
        if trashed {
            menu.addItem(LibraryMenuItem("복원") { perform { try library.restore(documentIDs: ids, folderIDs: ids) } })
            menu.addItem(LibraryMenuItem("영구 삭제…") { requestDelete(ids) })
        } else {
            if ids.count == 1 {
                menu.addItem(LibraryMenuItem("열기") { openEntry(entry.id) })
                menu.addItem(LibraryMenuItem("이름 변경") {
                    if inSidebar { libraryRenamingID = nil; sidebarRenamingID = entry.id }
                    else { sidebarRenamingID = nil; libraryRenamingID = entry.id }
                })
            }
            menu.addItem(.separator())
            menu.addItem(LibraryMenuItem("휴지통으로 이동") { trash(ids) })
        }
        return menu
    }
    private func newFolder() {
        guard !isTrash else { return }
        perform {
            let folder = try library.addFolder(parentID: currentFolder)
            search = ""
            sidebarRenamingID = nil
            selection = [folder.id]
            libraryRenamingID = folder.id
        }
    }
    private func backgroundMenu() -> NSMenu? {
        guard !isTrash else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(LibraryMenuItem("새 폴더") { newFolder() })
        let add = LibraryMenuItem("교안 추가…") { session.showingImporter = true }
        add.isEnabled = !library.isImporting
        menu.addItem(add)
        return menu
    }
    private func folderMenu(_ id: UUID) -> NSMenu {
        guard let folder = library.folders.first(where: { $0.id == id }) else { return NSMenu() }
        return menu(folderEntry(folder), [id], inSidebar: true)
    }
    private func trashMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = LibraryMenuItem("휴지통 비우기…") {
            let ids = Set(library.documents.filter { $0.trashedAt != nil }.map(\.id))
                .union(library.folders.filter { $0.trashedAt != nil }.map(\.id))
            guard !ids.isEmpty else { return }
            deletingIDs = ids; emptyingTrash = true; showingDelete = true
        }
        item.isEnabled = library.documents.contains { $0.trashedAt != nil } || library.folders.contains { $0.trashedAt != nil }
        menu.addItem(item)
        return menu
    }
    private func moveEntries(_ ids: Set<UUID>, to folder: UUID?) -> Bool {
        do { try library.move(ids, to: folder, undo: undoManager); return true }
        catch { library.error = error.localizedDescription; return false }
    }
    private func navigateToParent() {
        if session.document != nil { session.closeReader(); return }
        switch location {
        case .folder(let id):
            if let parentID = library.folders.first(where: { $0.id == id })?.parentID,
               activeFolders.contains(where: { $0.id == parentID }) { location = .folder(parentID) }
            else { location = .library }
        case .trashFolder(let id):
            if let folder = library.folders.first(where: { $0.id == id }), let group = folder.trashGroupID,
               let parentID = folder.parentID, let parent = library.folders.first(where: { $0.id == parentID }),
               parent.trashedAt != nil, (parent.trashGroupID ?? parent.id) == group {
                location = .trashFolder(parentID)
            } else { location = .trash }
        default: break
        }
    }
    private func commitRename(_ id: UUID, _ name: String) -> Bool {
        do {
            if let folder = library.folders.first(where: { $0.id == id && $0.trashedAt == nil }) {
                if folder.name != name { try library.rename(folder: folder, to: name) }
            } else if let document = library.documents.first(where: { $0.id == id && $0.trashedAt == nil }) {
                if document.name != name { try library.rename(document: document, to: name, undo: undoManager) }
            } else { throw LibraryError.invalidSelection }
            return true
        } catch { library.error = error.localizedDescription; return false }
    }
    private func trash(_ ids: Set<UUID>) { _ = trashEntries(ids) }
    private func trashEntries(_ ids: Set<UUID>) -> Bool {
        let folderIDs = Set(library.folders.filter { ids.contains($0.id) }.map(\.id))
        let subtree = library.descendantFolderIDs(of: folderIDs)
        let closesReader = session.document.map { ids.contains($0.id) || $0.folderID.map(subtree.contains) == true } ?? false
        do {
            try library.trash(documentIDs: ids, folderIDs: ids)
            if closesReader { session.closeReader() }
            if let currentFolder, subtree.contains(currentFolder) { location = .library }
            selection = []
            return true
        } catch { library.error = error.localizedDescription; return false }
    }
    private func requestDelete(_ ids: Set<UUID>) { guard !ids.isEmpty else { return }; deletingIDs = ids; emptyingTrash = false; showingDelete = true }
    private func deleteLookup(_ record: LookupRecord) {
        perform { try session.deleteLookup(record) }
    }
    private func deleteQuestion(_ record: QuestionRecord) {
        perform { try session.deleteQuestion(record) }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { library.error = error.localizedDescription } }
    private func finishDuplicate(copy: Bool) { let reply = duplicateReply; duplicateReply = nil; reply?.resume(returning: copy) }
    private func importFiles(_ urls: [URL], folder: UUID?) async {
        guard !library.isImporting else { library.error = "교안을 추가하는 중입니다. 완료된 뒤 다시 드래그하세요."; return }
        await library.importPDFs(urls, folderID: folder, onDuplicate: { existing in
            guard windowVisible else { return false }
            return await withCheckedContinuation { reply in duplicateName = existing.name; duplicateReply = reply }
        }, onOpenExisting: { if windowVisible { session.open($0) } })
    }
    private func exportPDF(_ document: LectureDocument, in window: NSWindow) {
        guard !isExporting, window.attachedSheet == nil else { return }
        isExporting = true
        let source = library.url(for: document), notes = library.notes(for: document)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = document.name + " - 뜻풀이.pdf"
        Task { @MainActor in
            defer { isExporting = false }
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do { try await Task.detached { try PDFExporter.export(source: source, notes: notes, destination: url) }.value }
            catch { library.error = error.localizedDescription }
        }
    }
    private func exportAnki(in window: NSWindow) {
        guard !isExporting, window.attachedSheet == nil else { return }
        isExporting = true
        let documents = Dictionary(uniqueKeysWithValues: library.documents.map { ($0.id, $0) })
        let paths = library.folderPaths
        let words = wordRecords.map { record in
            let document = documents[record.documentID]
            let subject = document?.folderID.flatMap { paths[$0] } ?? document?.name ?? "기타"
            return AnkiWord(word: record.text, meaning: record.shortText, context: record.explanation, subject: subject,
                            subjectID: document?.folderID ?? record.documentID)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apkg") ?? .data]
        panel.nameFieldStringValue = "영한번역 단어장.apkg"
        Task { @MainActor in
            defer { isExporting = false }
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            do { try await AnkiExporter.export(words: words, destination: url, deckName: "영한번역") }
            catch { library.error = error.localizedDescription }
        }
    }
}
