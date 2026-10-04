import SwiftUI

struct SpeechSettingsView: View {
    @Bindable var controller: SpeechController
    @AppStorage("audioRetention") private var audioRetention = "failed"
    @AppStorage("speechIdleMinutes") private var idleMinutes = 5
    @State private var deletion: LocalSpeechModel?
    @State private var choosingVariant: LocalSpeechModel?
    @State private var deletingRemnants = false

    var body: some View {
        @Bindable var models = controller.models
        Section("음성 인식") {
            modelPicker(for: .read)
            modelPicker(for: .question)
            Picker("질문 언어", selection: $controller.language) {
                Text("한국어").tag("ko-KR")
                Text("영어").tag("en-US")
            }
            Toggle("교안 용어 힌트", isOn: $controller.termHintsEnabled)
            Text("교안의 전문 용어를 참고해 받아쓴 질문을 교정합니다.")
                .font(.callout).foregroundStyle(.secondary)
            if controller.questionEngine == .whisper {
                Text("Whisper는 녹음을 마친 뒤 인식합니다. 계산 도중 취소하면 결과를 버리고 현재 계산이 끝난 뒤 메모리를 해제합니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("마이크를 시작할 때 선택한 모델을 준비합니다. 준비 중에는 녹음하지 않습니다.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .disabled(controller.mode != .idle)
        .onChange(of: controller.language) { _, _ in Task { await controller.checkAssets() } }

        Section("Apple 음성 자산") {
            assetRow("영어 읽기", status: controller.appleReadStatus, purpose: .read)
            assetRow("질문 언어", status: controller.appleQuestionStatus, purpose: .question)
            if controller.isInstallingAssets { ProgressView("시스템 음성 자산 준비 중") }
            Button("상태 다시 확인") { Task { await controller.checkAssets() } }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task {
            await controller.checkAssets()
            await controller.models.loadDiscoveryIfNeeded()
        }

        Section("설치된 음성 모델") {
            if controller.models.managedModels.isEmpty {
                Text("설치된 음성 모델이 없습니다. 아래에서 모델을 찾아 다운로드하세요.").foregroundStyle(.secondary)
            }
            ForEach(controller.models.managedModels) { modelRow($0) }
            if let error = controller.models.downloadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !controller.models.interrupted.isEmpty {
                Text("중단된 작업은 받은 파일부터 재사용합니다. 이어받기를 지원하지 않는 파일은 다시 받습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(deletingRemnants ? "다운로드 잔여 파일 삭제" : "음성 모델을 삭제할까요?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            if let deletion {
                Button(deletingRemnants ? "다운로드 잔여 파일 삭제" : "\(deletion.title) 삭제", role: .destructive) {
                    if deletingRemnants { Task { await controller.models.removeInterrupted(deletion) } }
                    else { Task { await controller.removeModel(deletion) } }
                    self.deletion = nil
                }
            }
        }

        Section("음성 모델 검색") {
            HStack {
                TextField("음성 모델 검색", text: $models.searchQuery, prompt: Text("음성 모델 검색"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .onSubmit { Task { await models.search(models.searchQuery) } }
                Button("검색") { Task { await models.search(models.searchQuery) } }
                    .disabled(controller.models.isSearching)
                if controller.models.isSearching { ProgressView().controlSize(.small) }
            }
            ForEach(controller.models.availableSearchResults) { modelRow($0) }
            if let error = controller.models.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(item: $choosingVariant) { model in
            SpeechModelVariantsView(store: controller.models, model: model)
        }

        Section("녹음 보관과 메모리") {
            Picker("녹음 보관", selection: $audioRetention) {
                Text("저장하지 않기").tag("none")
                Text("실패한 녹음만").tag("failed")
                Text("성공한 녹음만").tag("successful")
                Text("모든 녹음").tag("all")
            }
            Picker("사용 후 음성 모델 해제", selection: $idleMinutes) {
                Text("즉시").tag(0)
                Text("1분").tag(1)
                Text("5분").tag(5)
                Text("15분").tag(15)
            }
            Button("보관한 녹음 폴더 열기") {
                try? FileManager.default.createDirectory(at: SpeechController.recordingsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(SpeechController.recordingsDirectory)
            }
        }
    }

    private func modelRow(_ model: LocalSpeechModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).lineLimit(1).help(model.id)
                Text(model.engine == .qwen ? "영어 읽기 · 질문 받아쓰기" : "질문 받아쓰기 · 녹음 후 인식")
                    .font(.caption).foregroundStyle(.secondary)
                if let variant = model.variantTitle {
                    Text(variant).font(.caption).foregroundStyle(.secondary)
                }
                Text(modelSize(model)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.models.downloadingID == model.id {
                HStack(spacing: 4) {
                    if controller.models.totalBytes != nil {
                        ProgressView(value: controller.models.progress).frame(width: 110)
                        Text(controller.models.progress, format: .percent.precision(.fractionLength(1)))
                            .font(.caption).monospacedDigit().fixedSize()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("준비 중").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .help(controller.models.downloadDetail)
                Button("취소") { controller.models.cancelDownload() }
            } else if controller.models.installedIDs.contains(model.id) {
                Text("설치됨").foregroundStyle(.secondary)
                Button("삭제", role: .destructive) { deletingRemnants = false; deletion = model }
                    .disabled(controller.mode != .idle)
            } else {
                Button(controller.models.interrupted.contains(where: { $0.id == model.id }) ? "이어서 받기" : "버전 선택…") {
                    if controller.models.interrupted.contains(where: { $0.id == model.id }) {
                        Task { await controller.models.download(model) }
                    } else { choosingVariant = model }
                }
                .disabled(controller.models.downloadingID != nil || controller.models.removingInterruptedID == model.id)
                if controller.models.interrupted.contains(where: { $0.id == model.id }) {
                    Button(controller.models.removingInterruptedID == model.id ? "삭제 중…" : "잔여 파일 삭제", role: .destructive) {
                        deletingRemnants = true
                        deletion = model
                    }
                    .disabled(controller.models.removingInterruptedID != nil)
                }
            }
        }
    }

    private func modelSize(_ model: LocalSpeechModel) -> String {
        let downloading = controller.models.downloadingID == model.id
        guard let size = downloading ? controller.models.totalBytes : model.size else {
            if downloading { return "용량 확인 중" }
            return controller.models.managedModels.contains(where: { $0.id == model.id })
                ? "용량 확인 불가" : "버전 선택에서 다운로드 용량을 확인하세요."
        }
        let label = controller.models.installedIDs.contains(model.id) ? "설치 용량" : "다운로드 용량"
        return "\(label) \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }

    private func modelPicker(for purpose: SpeechMode) -> some View {
        let available = controller.availableModels(for: purpose)
        let selected = controller.modelSelection(for: purpose)
        let modelID = purpose == .read ? controller.readModelID : controller.questionModelID
        let missing = selected != "apple" && !available.contains { SpeechController.selectionKey(engine: $0.engine, modelID: $0.id) == selected }
        return Picker(purpose.title, selection: Binding(get: { controller.modelSelection(for: purpose) }, set: { controller.selectModel($0, for: purpose) })) {
            Text("Apple 시스템 인식").tag("apple")
            if missing {
                Text(modelID.isEmpty ? "모델 선택" : "\(modelID) · 설치되지 않음 또는 사용 불가")
                    .tag(selected).disabled(true)
            }
            ForEach(available) { model in
                Text(model.title + (model.variantTitle.map { " · \($0)" } ?? ""))
                    .tag(SpeechController.selectionKey(engine: model.engine, modelID: model.id))
            }
        }
    }
    private func assetRow(_ name: String, status: String, purpose: SpeechMode) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(status).foregroundStyle(.secondary)
            if status == "다운로드 필요" {
                Button("다운로드") { Task { await controller.installAppleAssets(for: purpose) } }
                    .disabled(controller.isInstallingAssets)
            }
        }
    }
}

private struct SpeechModelVariantsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: LocalSpeechModels
    let model: LocalSpeechModel
    @State private var variants: [SpeechModelVariant] = []
    @State private var selected = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(model.title) 버전 선택").font(.title2).lineLimit(2)
            Text("버전과 다운로드 용량을 확인하고 사용할 버전을 선택하세요.")
                .font(.callout).foregroundStyle(.secondary)
            if loading { ProgressView("버전 목록 확인 중…") }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List(variants, selection: $selected) { variant in
                HStack {
                    Text(variant.title)
                    if variant.isDefault { Text("기본").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: variant.size, countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                }.tag(variant.id)
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("다운로드") {
                    guard let variant = variants.first(where: { $0.id == selected }) else { return }
                    Task { await store.download(variant.model) }
                    dismiss()
                }
                .disabled(selected.isEmpty || store.downloadingID != nil || store.installedIDs.contains(model.id))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 460)
        .task {
            do {
                let options = try await store.modelVariants(model)
                try Task.checkCancellation()
                variants = options
                selected = options.first(where: \.isDefault)?.id ?? options.first?.id ?? ""
                if options.isEmpty { error = "다운로드할 수 있는 버전을 찾지 못했습니다." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            loading = false
        }
    }
}
