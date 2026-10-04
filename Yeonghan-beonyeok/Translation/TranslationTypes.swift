import Foundation

enum TranslationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, local
    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .local: "로컬 · Ollama"
        }
    }
}

struct TranslationOptions: Codable, Equatable, Sendable {
    var model: String
    var effort = ""
    var fast = false
}

struct TranslationConfiguration: Codable, Equatable, Sendable {
    var provider: TranslationProvider = .codex
    var codex = TranslationOptions(model: "gpt-6-sol", effort: "low")
    var claude = TranslationOptions(model: "haiku")
    var local = TranslationOptions(model: "")
    var localIdleMinutes = 10

    var selected: TranslationOptions {
        get {
            switch provider {
            case .codex: codex
            case .claude: claude
            case .local: local
            }
        }
        set {
            switch provider {
            case .codex: codex = newValue
            case .claude: claude = newValue
            case .local: local = newValue
            }
        }
    }
}

struct TranslationModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var efforts: [String] = []
    var supportsFast = false
}

struct CLIInstallation: Equatable, Sendable {
    var path: URL?
    var version: String?
    var isChecking = false
    var error: String?

    var status: String {
        if path == nil { return "미설치" }
        if isChecking { return "확인 중" }
        return error == nil ? "설치됨" : "실행 확인 필요"
    }

    var source: String? {
        guard let path else { return nil }
        let resolved = path.resolvingSymlinksInPath().path
        if ["/opt/homebrew/Cellar/", "/opt/homebrew/Caskroom/", "/usr/local/Cellar/", "/usr/local/Caskroom/"].contains(where: resolved.hasPrefix) {
            return "Homebrew CLI"
        }
        if path.path.contains(".app/Contents/") { return "앱에 포함된 CLI" }
        if path.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + "/") {
            return "사용자 CLI (.local)"
        }
        return nil
    }
}

struct TranslationRequest: Sendable {
    enum Kind: String, Codable, Sendable { case word, sentence }
    let text: String
    let pageText: String
    let subject: String
    let kind: Kind
}

struct TranslationAnswer: Sendable {
    let shortText: String
    let explanation: String
}

struct TranslationFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
