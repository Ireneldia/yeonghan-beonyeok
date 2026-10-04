import AppKit
import Observation

enum OllamaInstallChoice: String, CaseIterable, Identifiable {
    case homebrewCLI, homebrewApp, officialScript
    var id: String { rawValue }
    var title: String {
        switch self {
        case .homebrewCLI: "Homebrew · CLI와 서버"
        case .homebrewApp: "Homebrew · 공식 Ollama 앱"
        case .officialScript: "Ollama 공식 스크립트"
        }
    }
    var arguments: [String] {
        switch self {
        case .homebrewCLI: ["install", "--formula", "--force-bottle", "ollama"]
        case .homebrewApp: ["install", "--cask", "ollama-app"]
        case .officialScript: []
        }
    }
}

private struct SetupFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The app owns one instance, shared by the wizard and Settings.
@Observable @MainActor
final class OllamaSetupController {
    enum Readiness: String {
        case unchecked = "확인 전", missing = "미설치", stopped = "설치됨 · 중지됨"
        case ready = "연결됨", attention = "확인 필요"
    }

    var choice: OllamaInstallChoice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "ollama.installChoice") }
    }
    private(set) var readiness = Readiness.unchecked
    private(set) var isBusy = false
    private(set) var stage = ""
    private(set) var error: String?
    private(set) var logs = ""
    private(set) var version: String?
    private(set) var detectedInstallation = "확인 전"
    private(set) var brewPath: URL?
    private(set) var cliPath: URL?
    private(set) var appPath: URL?
    private(set) var hasFormula = false
    private(set) var hasCask = false
    private(set) var portOccupied = false
    private(set) var awaitingHomebrew = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var server: Process?
    @ObservationIgnored private var detectionIssue: String?
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        choice = OllamaInstallChoice(rawValue: UserDefaults.standard.string(forKey: "ollama.installChoice") ?? "") ?? .homebrewCLI
        awaitingHomebrew = UserDefaults.standard.bool(forKey: "ollama.awaitingHomebrew")
        if awaitingHomebrew { stage = "Homebrew 설치를 완료한 뒤 계속하세요." }
        else if UserDefaults.standard.bool(forKey: "ollama.installInProgress") {
            stage = "이전 작업이 중단되었습니다. 설치 상태를 확인한 뒤 이어서 진행하세요."
        }
    }

    var isReady: Bool { readiness == .ready }
    var previousChoice: OllamaInstallChoice? {
        defaults.string(forKey: "ollama.installChoice").flatMap(OllamaInstallChoice.init(rawValue:))
    }
    var isInstalled: Bool { cliPath != nil || appPath != nil || hasFormula || hasCask || isReady }
    var hasMixedInstallations: Bool { hasFormula && (hasCask || appPath != nil) }
    var canInstall: Bool { !isInstalled && !portOccupied && detectionIssue == nil && readiness != .unchecked }
    var pendingTerminal: Bool { defaults.string(forKey: "ollama.terminalJob") != nil }
    var installationSummary: String {
        if choice == .officialScript {
            return "공식 스크립트를 내려받아 Terminal에서 Ollama.app을 설치합니다. 관리자 인증이 필요하면 Terminal에서 직접 진행합니다. 앱은 비밀번호를 받지 않습니다."
        }
        let prefix = brewPath == nil ? "Apple Silicon용 Homebrew.pkg를 내려받아 macOS Installer에서 먼저 설치합니다. 시스템 관리자 승인이 필요할 수 있습니다. 그다음 " : "기존 Homebrew로 "
        return prefix + (choice == .homebrewCLI ? "Ollama CLI와 서버를 설치합니다. 로그인 시 자동 실행은 등록하지 않습니다." : "공식 Ollama 앱을 설치합니다.")
    }

    func detect() async {
        guard operation == nil else { return }
        await perform {
            self.stage = "설치와 연결 상태 확인 중"
            await self.detectState()
            self.stage = self.isReady ? "로컬 번역 실행기 준비 완료" : "설치 상태 확인 완료"
        }
    }

    /// Call only in response to the install/resume button. Detection never installs.
    func install() async {
        guard operation == nil else { return }
        let selected = choice
        defaults.set(selected.rawValue, forKey: "ollama.installChoice")
        await perform {
            self.defaults.set(true, forKey: "ollama.installInProgress")
            await self.detectState()
            if self.pendingTerminal {
                try await self.observeTerminalJob()
                return
            }
            if self.isInstalled {
                try await self.startDetectedInstallation()
                return
            }
            guard self.canInstall else {
                throw SetupFailure(self.detectionIssue ?? "11434 포트의 응답을 확인할 수 없습니다. 기존 서버 상태를 확인한 뒤 다시 시도하세요.")
            }
            if selected != .officialScript {
                guard let brew = self.brewPath else {
                    try await self.prepareHomebrew()
                    return
                }
                try await self.validateHomebrew(brew)
                // Recheck immediately before installing, including after a system Installer handoff.
                await self.detectState()
                guard self.canInstall else {
                    if self.isInstalled { try await self.startDetectedInstallation(); return }
                    throw SetupFailure("설치 환경이 바뀌었습니다. 연결 상태를 다시 확인하세요.")
                }
                self.awaitingHomebrew = false
                self.defaults.set(false, forKey: "ollama.awaitingHomebrew")
                self.stage = "\(selected.title) 설치 중"
                _ = try await self.command(brew, selected.arguments, timeout: 1_800)
                await self.detectState()
                guard self.isInstalled else { throw SetupFailure("설치 명령은 끝났지만 Ollama를 찾지 못했습니다. 상세 출력을 확인하세요.") }
                try await self.startDetectedInstallation()
            } else {
                try await self.prepareOfficialScript()
            }
        }
    }

    func startIfNeeded() async {
        guard operation == nil else { return }
        await perform {
            await self.detectState()
            try await self.startDetectedInstallation()
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        error = nil
        let task = Task { @MainActor in
            do { try await action() }
            catch {
                self.error = Self.conciseError(error)
                self.appendLog(error.localizedDescription)
                self.stage = "작업을 완료하지 못했습니다"
                await self.detectState()
            }
            self.isBusy = false
            self.operation = nil
        }
        operation = task
        await task.value
    }

    private func detectState() async {
        detectionIssue = nil
        version = nil
        let nativeBrew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        brewPath = FileManager.default.isExecutableFile(atPath: nativeBrew.path) ? nativeBrew : GUIProcess.executable(named: "brew")
        let registeredApps = ["com.ollama.ollama", "com.electron.ollama"].compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.executableURL?.lastPathComponent == "Ollama" }?.bundleURL
        let apps = [URL(fileURLWithPath: "/Applications/Ollama.app"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Ollama.app")]
            + registeredApps + [runningApp].compactMap { $0 }
        appPath = apps.first { FileManager.default.fileExists(atPath: $0.path) }
        cliPath = GUIProcess.executable(named: "ollama")
        if cliPath == nil, let appPath {
            let embedded = appPath.appending(path: "Contents/Resources/ollama")
            if FileManager.default.isExecutableFile(atPath: embedded.path) { cliPath = embedded }
        }
        hasFormula = false
        hasCask = false
        if let brewPath {
            do {
                let formula = try await command(brewPath, ["list", "--formula", "--versions"], record: false)
                hasFormula = formula.status == 0 && formula.output.split(separator: "\n").contains { $0.hasPrefix("ollama ") }
                if let installed = formula.output.split(separator: "\n").first(where: { $0.hasPrefix("ollama ") }) {
                    version = installed.split(separator: " ").dropFirst().first.map(String.init)
                }
                let cask = try await command(brewPath, ["list", "--cask", "--versions"], record: false)
                hasCask = cask.status == 0 && cask.output.split(separator: "\n").contains { $0.hasPrefix("ollama-app ") }
                if hasFormula && cliPath == nil {
                    let unlinked = brewPath.deletingLastPathComponent().deletingLastPathComponent().appending(path: "opt/ollama/bin/ollama")
                    if FileManager.default.isExecutableFile(atPath: unlinked.path) { cliPath = unlinked }
                }
            } catch {
                detectionIssue = "Homebrew 설치 기록을 확인하지 못했습니다. 상세 출력에서 오류를 확인하세요."
                appendLog(error.localizedDescription)
            }
        }
        var detected: [String] = []
        if hasFormula { detected.append("Homebrew CLI") }
        if hasCask { detected.append("Homebrew 공식 앱") }
        else if appPath != nil { detected.append("Ollama 앱") }
        if detected.isEmpty, cliPath != nil { detected.append("기존 CLI") }
        detectedInstallation = detected.isEmpty ? "발견되지 않음" : detected.joined(separator: " · ")
        version = appPath.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? version
        await detectConnection()
    }

    private func detectConnection() async {
        portOccupied = false
        do {
            struct Version: Decodable { let version: String }
            struct Tags: Decodable { let models: [Model]; struct Model: Decodable { let name: String } }
            let response: Version = try await request("http://127.0.0.1:11434/api/version", timeout: 2)
            let _: Tags = try await request("http://127.0.0.1:11434/api/tags", timeout: 2)
            guard !response.version.isEmpty else { throw SetupFailure("버전 응답이 비어 있습니다.") }
            version = response.version
            readiness = .ready
            if cliPath == nil && appPath == nil && !hasFormula && !hasCask { detectedInstallation = "실행 중인 Ollama API" }
        } catch {
            let listener = try? await command(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-iTCP:11434", "-sTCP:LISTEN"], allowFailure: true, record: false)
            portOccupied = !(listener?.output.isEmpty ?? true)
            let urlError = error as? URLError
            if urlError?.code != .cannotConnectToHost { portOccupied = true }
            readiness = portOccupied || detectionIssue != nil ? .attention : (cliPath != nil || appPath != nil || hasFormula || hasCask ? .stopped : .missing)
        }
    }

    private func startDetectedInstallation() async throws {
        if isReady { finish(); return }
        guard !portOccupied else { throw SetupFailure("11434 포트가 사용 중이지만 Ollama API를 확인하지 못했습니다. 해당 서버를 확인하세요.") }
        guard !hasMixedInstallations else { throw SetupFailure("CLI와 앱 설치가 함께 발견되었습니다. 사용할 Ollama를 직접 실행한 뒤 연결을 다시 확인하세요.") }
        stage = "Ollama 실행 및 연결 확인 중"
        if let appPath {
            _ = try await command(URL(fileURLWithPath: "/usr/bin/open"), ["-a", appPath.path, "--args", "hidden"])
        } else if hasFormula, let brewPath {
            _ = try await command(brewPath, ["services", "run", "ollama"], timeout: 60)
        } else if let cliPath {
            if server?.isRunning != true {
                // This is a shared server. No cancel, termination handler, or app-exit cleanup owns its lifetime.
                let process = Process()
                process.executableURL = cliPath
                process.arguments = ["serve"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                server = process
            }
        } else { throw SetupFailure("Ollama가 설치되어 있지 않습니다. 설치 방법을 선택하세요.") }
        for _ in 0..<20 {
            try await Task.sleep(for: .seconds(1))
            await detectConnection()
            if isReady { finish(); return }
        }
        throw SetupFailure("Ollama는 설치되어 있지만 연결되지 않았습니다. Ollama 앱의 초기 설정이나 실행 오류를 확인하고 다시 시도하세요.")
    }

    private func finish() {
        stage = "로컬 번역 실행기 준비 완료 · 설정에서 모델을 선택하세요."
        defaults.set(false, forKey: "ollama.installInProgress")
        defaults.set(false, forKey: "ollama.awaitingHomebrew")
        awaitingHomebrew = false
        if let identifier = defaults.string(forKey: "ollama.homebrewJob"), UUID(uuidString: identifier) != nil {
            try? FileManager.default.removeItem(at: jobsRoot.appendingPathComponent(identifier))
            defaults.removeObject(forKey: "ollama.homebrewJob")
        }
    }

    private func validateHomebrew(_ brew: URL) async throws {
        let result = try await command(brew, ["--prefix"], record: false)
        let prefix = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix == "/opt/homebrew" else { throw SetupFailure("Apple Silicon 기본 경로 /opt/homebrew의 Homebrew가 필요합니다. 현재 경로: \(prefix). 공식 스크립트 경로를 사용할 수도 있습니다.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: prefix)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), FileManager.default.isWritableFile(atPath: prefix) else {
            throw SetupFailure("Homebrew 소유 계정과 현재 계정이 다르거나 쓰기 권한이 없습니다. Homebrew를 설치한 계정에서 진행하세요.")
        }
    }

    private func prepareHomebrew() async throws {
        if awaitingHomebrew, let identifier = defaults.string(forKey: "ollama.homebrewJob"), UUID(uuidString: identifier) != nil {
            let package = jobsRoot.appendingPathComponent(identifier).appendingPathComponent("Homebrew.pkg")
            if FileManager.default.fileExists(atPath: package.path) {
                _ = try await command(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "com.apple.installer", package.path])
                stage = "Homebrew가 아직 확인되지 않습니다. Installer에서 설치를 마친 뒤 계속하세요."
                return
            }
        }
        stage = "공식 Homebrew 설치 패키지 다운로드 중"
        let folder = try jobDirectory()
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: folder) } }
        let package = folder.appendingPathComponent("Homebrew.pkg")
        try await download("https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg", to: package)
        // Installer performs its own signature and authorization checks. Never ask the app for a password.
        _ = try await command(URL(fileURLWithPath: "/usr/sbin/pkgutil"), ["--check-signature", package.path])
        try Task.checkCancellation()
        awaitingHomebrew = true
        defaults.set(folder.lastPathComponent, forKey: "ollama.homebrewJob")
        defaults.set(true, forKey: "ollama.awaitingHomebrew")
        // open can report an error after handing the package to Installer; retain the retry before calling it.
        handedOff = true
        _ = try await command(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "com.apple.installer", package.path])
        stage = "macOS Installer에서 Homebrew 설치를 마친 뒤 ‘설치 확인 후 계속’을 누르세요."
    }

    private func prepareOfficialScript() async throws {
        stage = "공식 Ollama 스크립트 다운로드 중"
        let folder = try jobDirectory()
        var handedOff = false
        defer { if !handedOff { try? FileManager.default.removeItem(at: folder) } }
        try await download("https://ollama.com/install.sh", to: folder.appendingPathComponent("ollama-install.sh"))
        // Guard again after downloading: the upstream script removes an existing app and stops Ollama.
        await detectState()
        guard canInstall else { throw SetupFailure("기존 Ollama 또는 서버가 발견되어 스크립트 설치를 중단했습니다. 기존 설치를 사용하세요.") }
        let script = """
        #!/bin/bash
        cd -- "$(/usr/bin/dirname -- "$0")" || exit 1
        umask 077
        echo $$ > installer.pid
        trap 'code=$?; printf "%s\\n" "$code" > result; exit "$code"' EXIT
        trap 'exit 130' INT TERM
        trap 'exit 129' HUP
        # Recheck at the Terminal boundary before the official installer can replace any existing app.
        if [ -e /Applications/Ollama.app ] || [ -e "$HOME/Applications/Ollama.app" ] || command -v ollama >/dev/null 2>&1 || [ -x /opt/homebrew/bin/ollama ] || [ -x /usr/local/bin/ollama ] || /usr/bin/pgrep -x Ollama >/dev/null 2>&1 || /usr/sbin/lsof -nP -iTCP:11434 -sTCP:LISTEN >/dev/null 2>&1; then
            echo "기존 Ollama 또는 실행 중인 서버가 발견되었습니다. 앱에서 연결을 다시 확인하세요."
            exit 75
        fi
        echo "Ollama 공식 설치를 시작합니다. 암호가 필요하면 Terminal에서 직접 입력하세요."
        OLLAMA_NO_START=1 /bin/sh ./ollama-install.sh > >(/usr/bin/tee install.log) 2>&1
        result=$?
        echo "설치 작업이 끝났습니다. 영한번역 앱에서 결과를 확인하세요."
        exit "$result"
        """
        let commandFile = folder.appendingPathComponent("Install Ollama.command")
        try script.write(to: commandFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandFile.path)
        try Task.checkCancellation()
        defaults.set(folder.lastPathComponent, forKey: "ollama.terminalJob")
        handedOff = true
        _ = try await command(URL(fileURLWithPath: "/usr/bin/open"), ["-b", "com.apple.Terminal", commandFile.path])
        try await observeTerminalJob()
    }

    private func observeTerminalJob() async throws {
        guard let identifier = defaults.string(forKey: "ollama.terminalJob"), UUID(uuidString: identifier) != nil else {
            throw SetupFailure("이전 Terminal 작업 정보를 읽을 수 없습니다.")
        }
        let folder = jobsRoot.appendingPathComponent(identifier)
        stage = "Terminal에서 설치 진행 중 · 권한 요청은 Terminal에서 승인하세요."
        for attempt in 0..<1_800 {
            if let output = try? Self.logTail(at: folder.appendingPathComponent("install.log")) { logs = output }
            if let raw = try? String(contentsOf: folder.appendingPathComponent("result"), encoding: .utf8),
               let status = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                defaults.removeObject(forKey: "ollama.terminalJob")
                await detectState()
                guard status == 0 else {
                    if status == 129 || status == 130 { throw SetupFailure("Terminal 설치가 취소되었습니다. 이미 설치된 항목은 유지되며, 상태를 확인한 뒤 다시 시도할 수 있습니다.") }
                    throw SetupFailure("공식 설치가 종료 코드 \(status)로 끝났습니다. Terminal의 오류를 확인하세요. 설치된 항목은 다시 설치하지 않습니다.")
                }
                guard isInstalled else { throw SetupFailure("스크립트는 끝났지만 Ollama 설치가 확인되지 않습니다. 상세 출력을 확인하세요.") }
                try await startDetectedInstallation()
                try? FileManager.default.removeItem(at: folder)
                return
            }
            if attempt > 5 {
                let pid = (try? String(contentsOf: folder.appendingPathComponent("installer.pid"), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if let pid, kill(pid, 0) != 0 && errno == ESRCH {
                    defaults.removeObject(forKey: "ollama.terminalJob")
                    throw SetupFailure("Terminal 설치가 중단되었습니다. 실제 설치 상태를 확인한 뒤 다시 시도하세요.")
                }
                if pid == nil && attempt > 30 {
                    defaults.removeObject(forKey: "ollama.terminalJob")
                    throw SetupFailure("Terminal에서 설치가 시작되지 않았습니다. Terminal 실행을 허용하고 다시 시도하세요.")
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw SetupFailure("Terminal 설치 결과를 아직 받지 못했습니다. Terminal을 확인한 뒤 ‘설치 결과 확인’을 누르세요.")
    }

    private var jobsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Yeonghan/Setup")
    }

    nonisolated private static func logTail(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
        let data = try file.read(upToCount: 32_768) ?? Data()
        let tail = size > 32_768 ? data.drop(while: { (0x80...0xBF).contains($0) }) : data
        return String(decoding: tail, as: UTF8.self)
    }

    private func jobDirectory() throws -> URL {
        let url = jobsRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func request<T: Decodable>(_ address: String, timeout: TimeInterval = 30) async throws -> T {
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SetupFailure("서버 응답을 확인하지 못했습니다.") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func download(_ address: String, to target: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: URL(string: address)!)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SetupFailure("설치 파일 다운로드가 실패했습니다.") }
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    @discardableResult
    private func command(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 30,
                         allowFailure: Bool = false, record: Bool = true) async throws -> GUIProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_SUDO"] = "1"
        if record { appendLog(executable.lastPathComponent + " " + arguments.joined(separator: " ")) }
        let result = try await GUIProcess(executable: executable, arguments: arguments, environment: environment).run(timeout: timeout) { line in
            if record { self.appendLog(line) }
        }
        if record, !result.errorOutput.isEmpty { appendLog(result.errorOutput) }
        guard allowFailure || result.status == 0 else { throw SetupFailure("\(executable.lastPathComponent) 종료 코드 \(result.status): \(result.errorOutput.isEmpty ? result.output : result.errorOutput)") }
        return result
    }

    private func appendLog(_ text: String) { logs = String((logs + "\n" + text).suffix(32_768)) }

    private static func conciseError(_ error: Error) -> String {
        if let url = error as? URLError {
            if url.code == .cancelled { return "다운로드가 취소되었습니다. 설치 상태를 다시 확인하세요." }
            return "네트워크 연결을 확인한 뒤 다시 시도하세요. \(url.localizedDescription)"
        }
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("no space left") || (error as NSError).code == NSFileWriteOutOfSpaceError { return "저장 공간이 부족합니다. 공간을 확보한 뒤 다시 시도하세요." }
        if lower.contains("permission denied") || lower.contains("sudo") { return "설치 권한이 필요합니다. 권한 요청을 취소했다면 다시 진행하거나 공식 스크립트를 선택하세요." }
        return String(text.prefix(350))
    }

}
