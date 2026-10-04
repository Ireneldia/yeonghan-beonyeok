import AppKit
import SwiftUI
import SwiftData

@main
struct Yeonghan_beonyeokApp: App {
    @NSApplicationDelegateAdaptor(NativeAppDelegate.self) private var delegate
    @State private var session: AppSession?
    private let startupError: String?
    private let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "영한번역"
    init() {
        do {
            let directory = try LibraryStore.dataDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = Schema([CourseFolder.self, LectureDocument.self, LookupRecord.self, QuestionRecord.self])
            let configuration = ModelConfiguration("Library", schema: schema,
                                                   url: directory.appendingPathComponent("Library.store"), cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            _session = State(initialValue: AppSession(library: try LibraryStore(container: container, directory: directory)))
            startupError = nil
        } catch {
            _session = State(initialValue: nil)
            startupError = error.localizedDescription
        }
    }

    var body: some Scene {
        Window(displayName, id: "main") {
            if let session {
                ContentView(session: session)
                    .onAppear { delegate.session = session }
                    .onOpenURL { url in
                        if url.isFileURL && url.pathExtension.lowercased() == "pdf" {
                            session.incomingURLs.append(url); session.showingImporter = true
                        }
                    }
                    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in session.speech.cancel() }
                    .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))) { _ in session.speech.cancel() }
            } else {
                ContentUnavailableView("라이브러리를 열지 못했습니다", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(startupError ?? "저장 폴더 접근 권한과 디스크 공간을 확인하세요."))
                    .frame(width: 620, height: 360)
            }
        }
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("교안 추가…") { session?.showingImporter = true }.keyboardShortcut("o")
                    .disabled(session == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("사이드바 전환") {
                    if let item = NSApp.keyWindow?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "sidebar" }), let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                }.keyboardShortcut("s", modifiers: [.command, .control])
                Button("교안 목록으로 돌아가기") { session?.closeReader() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("교안·단어·질문 검색") {
                    (NSApp.keyWindow?.toolbar?.items.first { $0 is NSSearchToolbarItem } as? NSSearchToolbarItem)?.beginSearchInteraction()
                }.keyboardShortcut("f")
            }
        }
        Settings {
            if let session { NativeSettingsView(session: session) }
        }
        MenuBarExtra(displayName, systemImage: "character.book.closed",
                     isInserted: Binding(get: { session?.preferences.showMenuBar ?? false }, set: { session?.preferences.showMenuBar = $0 })) {
            if let session { NativeStatusMenu(session: session) }
        }
    }
}

private struct NativeStatusMenu: View {
    @Bindable var session: AppSession
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("교안 보관함 열기") { openWindow(id: "main"); NSApp.activate() }
        if session.localModels.isDownloading { Text("모델 다운로드 중") }
        if let model = session.speech.models.downloadingID { Text("음성 모델 다운로드 중: \(model)") }
        if session.setup.isBusy { Text(session.setup.stage) }
        Divider()
        SettingsLink { Text("설정…") }
        Divider()
        Button("종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
