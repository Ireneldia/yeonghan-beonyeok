import SwiftUI
import UniformTypeIdentifiers

struct PDFImportSheet: View {
    let folders: [CourseFolder]
    let folderPaths: [UUID: String]
    let initialURLs: [URL]
    let initialFolder: UUID?
    let add: ([URL], UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urls: [URL] = []
    @State private var folder: UUID?
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PDF 교안 추가").font(.title2.bold())
            VStack(spacing: 12) {
                if urls.isEmpty {
                    Image(systemName: "doc.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("PDF를 여기에 드래그하세요")
                    Button("파일 선택…") { chooseFiles() }
                } else {
                    HStack {
                        Text("선택한 PDF \(urls.count)개").font(.headline)
                        Spacer()
                        Button("파일 더 추가…") { chooseFiles() }
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(urls, id: \.self) { url in
                                HStack {
                                    Label(url.lastPathComponent, systemImage: "doc.text")
                                        .lineLimit(1).truncationMode(.middle).help(url.path)
                                    Spacer()
                                    Button("제외", systemImage: "xmark.circle.fill") { urls.removeAll { $0 == url } }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                                        .accessibilityLabel("\(url.lastPathComponent) 제외")
                                }.frame(height: 28)
                            }
                        }
                    }.frame(height: min(208, CGFloat(urls.count) * 36))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .dropDestination(for: URL.self) { incoming, _ in append(incoming) } isTargeted: { targeted = $0 }
            Picker("저장할 폴더", selection: $folder) {
                Text("서재").tag(UUID?.none)
                ForEach(folders.sorted { (folderPaths[$0.id] ?? $0.name).localizedStandardCompare(folderPaths[$1.id] ?? $1.name) == .orderedAscending }) {
                    Text(folderPaths[$0.id] ?? $0.name).tag(Optional($0.id))
                }
            }
            HStack {
                Text("원본 파일은 그대로 유지됩니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("\(urls.isEmpty ? "" : "\(urls.count)개 ")추가") { add(urls, folder) }
                    .keyboardShortcut(.defaultAction).disabled(urls.isEmpty)
            }
        }.padding(24).frame(width: 580).onAppear { append(initialURLs); folder = initialFolder }
        .onChange(of: initialURLs) { _, incoming in append(incoming) }
    }
    @discardableResult private func append(_ incoming: [URL]) -> Bool {
        let pdfs = Self.pdfFiles(incoming)
        for url in pdfs where !urls.contains(url) { urls.append(url) }
        return !pdfs.isEmpty
    }
    private static func pdfFiles(_ incoming: [URL]) -> [URL] {
        incoming.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK { append(panel.urls) } }
    }
}

nonisolated final class LibraryMenuItem: NSMenuItem {
    private let operation: @MainActor () -> Void
    init(_ title: String, operation: @escaping @MainActor () -> Void) {
        self.operation = operation
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("LibraryMenuItem is created in code") }
    @MainActor @objc private func invoke() { operation() }
}
