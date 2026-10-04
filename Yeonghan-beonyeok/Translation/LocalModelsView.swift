import SwiftUI

struct LocalModelsView: View {
    @Bindable var store: LocalModelStore
    @State private var family: LocalModelOption?
    @State private var pendingDeletion: LocalModelOption?

    var body: some View {
        Form {
            Section("설치된 모델") {
                Text(store.memoryDescription).font(.caption).foregroundStyle(.secondary)
                if let error = store.error {
                    Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
                ForEach(store.downloads) { download in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(download.id, systemImage: download.state == .complete ? "checkmark.circle" : "arrow.down.circle")
                            Spacer()
                            if download.state == .downloading {
                                Button("중지") { store.cancelDownload(download.id) }
                            } else {
                                if download.state != .complete {
                                    Button("재시도") { store.startDownload(tag: download.id) }.disabled(store.isDownloading)
                                }
                                Button("닫기", systemImage: "xmark") { store.clearCard(download.id) }.labelStyle(.iconOnly)
                                    .help("다운로드 알림만 닫습니다. 모델 파일은 삭제하지 않습니다")
                            }
                        }
                        if download.state == .downloading {
                            if download.totalKnown, let fraction = download.fraction {
                                ProgressView(value: fraction)
                            } else { ProgressView().controlSize(.small) }
                        }
                        Text(download.status).font(.caption).foregroundStyle(.secondary)
                        if download.total > 0 {
                            Text("\(size(download.completed)) / \(size(download.total))\(download.totalKnown ? "" : " · 확인된 파일")")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.installedModels) { model in
                    HStack {
                        MemoryFitDot(fit: model.fit)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).textSelection(.enabled)
                            Text(model.isCloud ? "클라우드 연결 · 로컬 번역 불가" : model.size.map(size) ?? "용량 미확인")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.deleting.contains(model.id) { ProgressView().controlSize(.small) }
                        else {
                            Button("삭제…", role: .destructive) { pendingDeletion = model }
                                .disabled(store.downloads.contains { $0.id == model.id && $0.state == .downloading })
                        }
                    }
                }
                if store.installedModels.isEmpty && store.downloads.isEmpty {
                    Text("설치된 로컬 모델이 없습니다. 모델을 검색한 뒤 버전을 선택하세요")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("설치 목록 새로고침") { Task { await store.reload() } }.disabled(store.isRefreshing)
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("공식 모델 검색") {
                HStack {
                    TextField("모델 이름 검색", text: $store.searchQuery, prompt: Text("모델 이름 검색"))
                        .textFieldStyle(.roundedBorder).labelsHidden()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("모델 이름 검색")
                        .onSubmit { Task { await store.search(query: store.searchQuery) } }
                    Button("검색") { Task { await store.search(query: store.searchQuery) } }
                        .disabled(store.isSearching)
                    if store.isSearching { ProgressView().controlSize(.small) }
                }
                ForEach(store.searchResults) { model in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).font(.headline)
                            if !model.description.isEmpty {
                                Text(model.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        Spacer()
                        Button("버전 선택…") { family = model }
                    }.padding(.vertical, 3)
                }
                if store.searchResults.isEmpty && !store.isSearching {
                    Text("모델 이름을 검색하세요").foregroundStyle(.secondary)
                }
                Link("Ollama 공식 모델 목록", destination: URL(string: "https://ollama.com/search")!)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { await store.reload() }
        .sheet(item: $family) { model in ModelVariantsView(store: store, family: model.id) }
        .confirmationDialog("\(pendingDeletion?.name ?? "모델") 모델 파일을 삭제하시겠습니까?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let model = pendingDeletion {
                Button("모델 파일 삭제", role: .destructive) {
                    pendingDeletion = nil
                    Task { await store.deleteInstalled(model) }
                }
            }
            Button("취소", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("공유 Ollama 저장소에서 삭제되므로 이 모델을 쓰는 다른 앱에도 영향을 줍니다. 다시 사용하려면 다운로드해야 합니다.")
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private struct ModelVariantsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: LocalModelStore
    let family: String
    @State private var variants: [LocalModelOption] = []
    @State private var selected = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(family) 버전 선택").font(.title2)
            Text("크기와 양자화를 확인하고 로컬에서 사용할 버전을 선택하세요")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("버전 목록 확인 중…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List(variants, selection: $selected) { model in
                HStack {
                    MemoryFitDot(fit: model.fit)
                    Text(model.id)
                    Spacer()
                    if let size = model.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(.secondary) }
                    if store.installedModels.contains(where: { $0.id == model.id }) { Text("설치됨").foregroundStyle(.secondary) }
                }.tag(model.id)
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("다운로드") { store.startDownload(tag: selected); dismiss() }
                    .disabled(selected.isEmpty || store.isDownloading)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 460)
        .task {
            do {
                variants = try await store.modelVariants(name: family)
                if variants.isEmpty { error = "로컬에서 다운로드할 수 있는 버전을 찾지 못했습니다" }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            loading = false
        }
    }
}

private struct MemoryFitDot: View {
    let fit: ModelMemoryFit
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .help(fit.label + " · " + fit.note)
            .accessibilityLabel("메모리 적합도: " + fit.label)
    }
    private var color: Color {
        switch fit.level {
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .unknown: .secondary
        }
    }
}
