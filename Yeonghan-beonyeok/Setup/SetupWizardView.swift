import SwiftUI

struct SetupWizardView: View {
    let controller: OllamaSetupController
    @Bindable var translation: TranslationService
    let onFinish: (String?) -> Void
    @State private var provider = TranslationProvider.codex
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("영한번역 시작하기", systemImage: "character.book.closed")
                    .font(.largeTitle.bold())
                Text("번역에 사용할 연결 방식을 선택하세요. 나중에 설정에서 바꿀 수 있습니다.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Form {
                Section("번역 연결") {
                    TranslationProviderPicker(service: translation, selection: $provider)
                        .disabled(controller.isBusy)
                    if provider == .local {
                        Text("이 Mac의 Ollama를 사용합니다. 실행기를 준비한 뒤 설정에서 번역 모델을 선택하세요.")
                            .foregroundStyle(.secondary)
                    }
                }
                if provider == .local {
                    OllamaSetupView(controller: controller)
                } else {
                    CLIInstallationView(service: translation, provider: provider)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button("나중에 설정") { onFinish(nil) }
                Spacer()
                Button(provider == .local ? "로컬로 시작" : "시작하기") {
                    translation.refreshInstallations()
                    if translation.isProviderAvailable(provider) { onFinish(provider.rawValue) }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled((provider == .local && !controller.isReady) || !translation.isProviderAvailable(provider))
            }
            .padding(20)
        }
        .frame(width: 640, height: provider == .local ? 740 : 520)
        .interactiveDismissDisabled(controller.isBusy)
        .onAppear {
            provider = translation.configuration.provider
            refreshInstallations()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshInstallations() } }
    }

    private func refreshInstallations() {
        translation.refreshInstallations()
        if !translation.isProviderAvailable(provider) {
            provider = TranslationProvider.allCases.first { translation.isProviderAvailable($0) } ?? .local
        }
    }
}

/// Form sections reused directly by both the first-run wizard and Settings.
struct OllamaSetupView: View {
    @Bindable var controller: OllamaSetupController
    @State private var showsLog = false

    var body: some View {
        Section("로컬 번역 실행기 · Ollama") {
            LabeledContent("상태") {
                Label(controller.readiness.rawValue, systemImage: statusIcon)
                    .foregroundStyle(controller.isReady ? .green : .secondary)
            }
            LabeledContent("감지된 설치", value: controller.detectedInstallation)
            if controller.isInstalled, let previous = controller.previousChoice {
                LabeledContent("이전에 선택한 방법", value: previous.title)
            }
            if let version = controller.version { LabeledContent("버전", value: version) }
            if let path = controller.cliPath {
                LabeledContent("CLI 경로") { Text(path.path).textSelection(.enabled).font(.caption) }
            }
            if controller.hasMixedInstallations {
                Text("CLI와 앱이 함께 설치되어 있습니다. 기존 서버가 연결되어 있으면 그대로 사용합니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if controller.isReady {
                Text("실행기가 준비되었습니다. 모델은 모델 관리에서 따로 선택하고 다운로드하세요.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("연결 다시 확인") { Task { await controller.detect() } }
                if controller.isInstalled && !controller.isReady {
                    Button("기존 Ollama 실행") { Task { await controller.startIfNeeded() } }
                }
            }
            .disabled(controller.isBusy)
        }
        .task { await controller.detect() }

        if !controller.isInstalled {
            Section("설치 방법") {
                Picker("선택한 방법", selection: $controller.choice) {
                    ForEach(OllamaInstallChoice.allCases) { Text($0.title).tag($0) }
                }
                .disabled(controller.isBusy || controller.pendingTerminal)
                if controller.choice != .officialScript {
                    LabeledContent("Homebrew", value: controller.brewPath?.path ?? "추가 설치 필요")
                }
                Text(controller.installationSummary).foregroundStyle(.secondary)
                Text("설치 후 실행해 API 연결을 확인합니다. 모델 다운로드는 포함되지 않습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(installLabel) { Task { await controller.install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy || (!controller.canInstall && !controller.pendingTerminal))
                    if controller.choice == .officialScript {
                        Link("공식 설치 안내", destination: URL(string: "https://ollama.com/download/mac")!)
                    } else {
                        Link("Homebrew 설치 안내", destination: URL(string: "https://docs.brew.sh/Installation")!)
                    }
                }
            }
        } else if controller.pendingTerminal && !controller.isBusy {
            Section {
                Button("설치 결과 확인") { Task { await controller.install() } }
            }
        }

        if controller.isBusy || !controller.stage.isEmpty || controller.error != nil {
            Section("진행 상태") {
                HStack(alignment: .top, spacing: 10) {
                    if controller.isBusy { ProgressView().controlSize(.small) }
                    Text(controller.stage).foregroundStyle(.secondary)
                }
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if !controller.logs.isEmpty {
                    DisclosureGroup("상세 설치 출력", isExpanded: $showsLog) {
                        ScrollView {
                            Text(controller.logs)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                }
            }
        }
    }

    private var statusIcon: String {
        switch controller.readiness {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle"
        case .stopped: "pause.circle"
        case .unchecked: "questionmark.circle"
        case .missing: "arrow.down.circle"
        }
    }
    private var installLabel: String {
        if controller.pendingTerminal { return "설치 결과 확인" }
        if controller.awaitingHomebrew && controller.choice != .officialScript { return "설치 확인 후 계속" }
        if controller.error != nil { return "다시 시도" }
        return controller.choice == .officialScript ? "Terminal에서 설치" : "설치 시작"
    }
}
