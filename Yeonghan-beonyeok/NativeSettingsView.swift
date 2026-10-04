import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "일반", translation = "번역", speech = "음성 인식", models = "로컬 모델", ollama = "Ollama 설치", storage = "저장 공간"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .translation: "character.bubble"
        case .speech: "waveform"
        case .models: "internaldrive"
        case .ollama: "arrow.down.circle"
        case .storage: "externaldrive"
        }
    }
}

struct NativeSettingsView: View {
    @Bindable var session: AppSession
    @Bindable private var preferences: AppPreferences
    init(session: AppSession) { self.session = session; self.preferences = session.preferences }
    @State private var section = SettingsSection.general
    @State private var showSetup = false
    @AppStorage("audioRetention") private var audioRetention = "failed"
    var body: some View {
        HSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item).listRowSeparator(.hidden)
            }.listStyle(.inset).alternatingRowBackgrounds(.disabled).scrollContentBackground(.hidden)
                .font(.body).environment(\.defaultMinListRowHeight, 32)
                .padding(.top, 8)
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)
            Group {
                switch section {
                case .general: general
                case .translation: TranslationSettingsView(service: session.translation, setup: session.setup)
                case .models: LocalModelsView(store: session.localModels)
                case .speech: Form { SpeechSettingsView(controller: session.speech) }.formStyle(.grouped).scrollContentBackground(.hidden)
                case .ollama: Form { OllamaSetupView(controller: session.setup) }.formStyle(.grouped).scrollContentBackground(.hidden)
                case .storage: storage
                }
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 640)
        .background(WindowLifecycle())
        .containerBackground(.regularMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .preferredColorScheme(session.preferences.colorScheme)
        .navigationTitle(section.rawValue)
        .sheet(isPresented: $showSetup) {
            SetupWizardView(controller: session.setup, translation: session.translation) { provider in
                if let provider, let value = TranslationProvider(rawValue: provider) { session.translation.configuration.provider = value }
                session.preferences.setupComplete = true; showSetup = false
            }
        }
    }

    private var general: some View {
        Form {
            Section("모양") {
                Picker("화면 모드", selection: $preferences.appearance) {
                    Text("시스템 설정").tag("system"); Text("밝게").tag("light"); Text("어둡게").tag("dark")
                }
                Toggle("메뉴 막대에 아이콘 표시", isOn: $preferences.showMenuBar)
            }
            Section("전력과 메모리") {
                Toggle("저전력 모드에서 모델 예열 줄이기", isOn: $preferences.respectLowPower)
            }
            Section("주석") {
                ColorPicker("기본 색상", selection: Binding(get: {
                    Color(nsColor: (AnnotationColor(hex: preferences.annotationColorHex) ?? .defaultColor).nsColor)
                }, set: { color in
                    if let hex = AnnotationColor.hex(from: NSColor(color)) { preferences.annotationColorHex = hex }
                }), supportsOpacity: false)
                Text("새로 만든 주석에 적용됩니다. 각 주석의 색상은 교안 오른쪽에서 변경할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("시작 설정") {
                Button("설정 마법사 다시 열기") { showSetup = true }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var storage: some View {
        Form {
            Section("휴지통") {
                Picker("자동 영구 삭제", selection: $preferences.trashRetentionDays) {
                    Text("자동 삭제 안 함").tag(0)
                    Text("7일 후").tag(7); Text("30일 후").tag(30); Text("90일 후").tag(90)
                }
                Text("교안과 번역·질문이 함께 복구됩니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("음성 녹음") {
                Picker("녹음 보관", selection: $audioRetention) {
                    Text("저장하지 않기").tag("none")
                    Text("성공한 녹음만").tag("successful")
                    Text("실패한 녹음만").tag("failed")
                    Text("모든 녹음").tag("all")
                }
            }
            Section("파일") {
                Button("앱 저장 폴더 열기") { NSWorkspace.shared.open(session.library.directory) }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
