import SwiftUI

struct TranslationSettingsView: View {
    @Bindable var service: TranslationService
    let setup: OllamaSetupController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("번역") {
                TranslationProviderPicker(service: service, selection: $service.configuration.provider)
                LabeledContent("모델") {
                    Menu {
                        Button("모델 선택") { modelBinding.wrappedValue = "" }
                        ForEach(service.availableModels) { model in
                            Button { modelBinding.wrappedValue = model.id } label: {
                                if model.id == service.configuration.selected.model { Label(model.name, systemImage: "checkmark") }
                                else { Text(model.name) }
                            }
                        }
                    } label: {
                        Text(service.selectedModelLabel)
                    }
                    .disabled(!service.isProviderAvailable(service.configuration.provider) || service.isRefreshing)
                    .accessibilityLabel("번역 모델")
                }
                if service.configuration.provider == .local, service.hasModelCatalog, service.availableModels.isEmpty {
                    Text("번역에 사용할 수 있는 로컬 모델이 없습니다. 모델 관리에서 텍스트 생성 모델을 다운로드하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("추론 수준", selection: $service.configuration.selected.effort) {
                    Text("모델 기본값").tag("")
                    if !service.configuration.selected.effort.isEmpty,
                       !(service.currentModel?.efforts.contains(service.configuration.selected.effort) ?? false) {
                        Text(service.configuration.selected.effort + " · 확인 필요").tag(service.configuration.selected.effort)
                    }
                    ForEach(service.currentModel?.efforts ?? [], id: \.self) { effort in
                        Text(effortName(effort)).tag(effort)
                    }
                }
                .disabled((service.currentModel?.efforts.isEmpty ?? true) && service.configuration.selected.effort.isEmpty)
                if service.configuration.provider != .local {
                    Toggle("Fast 요청", isOn: $service.configuration.selected.fast)
                        .disabled(!service.isProviderAvailable(service.configuration.provider) || (!(service.currentModel?.supportsFast ?? false) && !service.configuration.selected.fast))
                    if service.configuration.provider == .claude {
                        if ["default", "default[1m]"].contains(service.configuration.selected.model) {
                            Text("Fast를 사용하려면 지원되는 Opus 모델을 직접 선택하세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Claude Fast는 구독 포함 사용량과 별도로 사용 크레딧을 사용합니다. 계정·조직 조건에 따라 제공되며, 요청 설정만으로 실제 적용을 보장하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("Claude Fast 안내", destination: URL(string: "https://code.claude.com/docs/en/fast-mode")!)
                    } else if service.configuration.selected.fast {
                        Text("Codex Fast는 구독 사용량을 더 빠르게 소모할 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if service.configuration.selected.fast || service.fastFallbackReported {
                        Text(service.fastStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("설치 상태·모델 다시 확인") { Task { await service.refreshModels() } }
                        .disabled(service.isRefreshing)
                    if service.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text(service.status).font(.caption).foregroundStyle(.secondary)
                if let error = service.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if service.configuration.provider != .local {
                CLIInstallationView(service: service, provider: service.configuration.provider)
            } else {
                OllamaSetupView(controller: setup)
            }
            if service.configuration.provider == .local {
                Section("로컬 모델") {
                    Picker("사용 후 유지 시간", selection: $service.configuration.localIdleMinutes) {
                        Text("1분").tag(1)
                        Text("5분").tag(5)
                        Text("10분").tag(10)
                        Text("30분").tag(30)
                        Text("60분").tag(60)
                    }
                    Text("앱의 마지막 요청 이후 유지 시간을 Ollama에 전달합니다. 다른 앱의 사용에 따라 적재 시간이 달라질 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: service.configuration.provider) { await service.refreshModels() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { service.refreshInstallations() } }
    }

    private var modelBinding: Binding<String> {
        Binding(get: { service.configuration.selected.model }, set: { model in
            service.configuration.selected.model = model
            if !(service.currentModel?.efforts.contains(service.configuration.selected.effort) ?? false) {
                service.configuration.selected.effort = ""
            }
            if !(service.currentModel?.supportsFast ?? false) { service.configuration.selected.fast = false }
        })
    }

    private func effortName(_ value: String) -> String {
        ["off": "끄기", "on": "켜기", "none": "없음", "minimal": "최소", "low": "낮음", "medium": "중간",
         "high": "높음", "xhigh": "매우 높음", "max": "최대", "ultra": "Ultra"][value] ?? value
    }
}

struct CLIInstallationView: View {
    let service: TranslationService
    let provider: TranslationProvider
    @Environment(\.scenePhase) private var scenePhase

    private var installation: CLIInstallation { service.cliInstallations[provider] ?? CLIInstallation() }

    var body: some View {
        Section("\(provider.title) CLI") {
            LabeledContent("상태") {
                Label(installation.status, systemImage: installation.path == nil ? "arrow.down.circle" : installation.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(installation.error != nil ? Color.orange : installation.version != nil ? .green : .secondary)
            }
            if let source = installation.source { LabeledContent("감지된 설치", value: source) }
            if let version = installation.version { LabeledContent("버전", value: version) }
            if let path = installation.path {
                LabeledContent("CLI 경로") { Text(path.path).font(.caption).textSelection(.enabled) }
            } else {
                Text("\(provider.title) CLI를 설치한 뒤 다시 확인하세요.")
                    .foregroundStyle(.secondary)
            }
            if let error = installation.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("설치 상태 다시 확인") { Task { await service.refreshCLIStatus(provider) } }
                    .buttonStyle(.bordered).disabled(installation.isChecking)
                if installation.isChecking { ProgressView().controlSize(.small) }
            }
        }
        .task(id: provider) { await service.refreshCLIStatus(provider) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await service.refreshCLIStatus(provider) } }
        }
    }
}

/// Explicit menu actions respect item availability on macOS, including in the setup wizard.
struct TranslationProviderPicker: View {
    let service: TranslationService
    @Binding var selection: TranslationProvider

    var body: some View {
        LabeledContent("연결 방식") {
            Menu {
                ForEach(TranslationProvider.allCases) { provider in
                    Button {
                        service.refreshInstallations()
                        if service.isProviderAvailable(provider) { selection = provider }
                    } label: {
                        if selection == provider { Label(title(provider), systemImage: "checkmark") }
                        else { Text(title(provider)) }
                    }
                    .disabled(!service.isProviderAvailable(provider))
                }
            } label: { Text(title(selection)) }
            .fixedSize()
            .accessibilityLabel("연결 방식")
        }
    }

    private func title(_ provider: TranslationProvider) -> String {
        provider.title + (service.isProviderAvailable(provider) ? "" : " · 미설치")
    }
}
