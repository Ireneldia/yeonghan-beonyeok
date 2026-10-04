import AVFoundation
import Observation
import Speech
@preconcurrency import MLXAudioSTT

enum SpeechMode: String, Sendable, Codable {
    case read, question
    var title: String { self == .read ? "영어 읽기" : "질문 받아쓰기" }
}

enum SpeechEngine: String, Sendable, Codable {
    case apple, qwen, whisper
}

nonisolated struct SpeechFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated private struct SpeechRecordingSnapshot: Codable, Sendable {
    var fileName: String
    let purpose: SpeechMode
    let engine: SpeechEngine
    let modelID: String
    let language: String
    var documentID: UUID? = nil
    var correctionTerms: [String]? = nil
}

@Observable @MainActor
final class SpeechController {
    enum State: String { case idle, preparing, listening, transcribing }
    private(set) var mode = State.idle
    private(set) var activeMode: SpeechMode?
    private(set) var partialText = ""
    private(set) var error: String?
    private(set) var lastRecordingURL: URL?
    private(set) var lastRecordingDocumentID: UUID?
    private(set) var appleReadStatus = "확인 전"
    private(set) var appleQuestionStatus = "확인 전"
    private(set) var isInstallingAssets = false
    private(set) var correctionTerms: [String] = []
    var termHintsEnabled: Bool { didSet { UserDefaults.standard.set(termHintsEnabled, forKey: "speechTermHintsEnabled") } }
    var readEngine: SpeechEngine { didSet { UserDefaults.standard.set(readEngine.rawValue, forKey: "speechReadEngine") } }
    var questionEngine: SpeechEngine { didSet { UserDefaults.standard.set(questionEngine.rawValue, forKey: "speechQuestionEngine") } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: "speechLanguage") } }
    var readModelID: String { didSet { UserDefaults.standard.set(readModelID, forKey: "speechReadModel") } }
    var questionModelID: String { didSet { UserDefaults.standard.set(questionModelID, forKey: "speechQuestionModel") } }
    let models: LocalSpeechModels
    @ObservationIgnored private let recordingsFolder: URL
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var capture: SpeechAudioCapture?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var resultTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var deviceObserver: NSObjectProtocol?
    @ObservationIgnored private var activeID = UUID()
    @ObservationIgnored private var assetCheckID = UUID()
    @ObservationIgnored private var confirmedText = ""
    @ObservationIgnored private var onResult: ((String) -> Void)?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordingSnapshot: SpeechRecordingSnapshot?
    @ObservationIgnored private var lastRecordingSnapshot: SpeechRecordingSnapshot?
    @ObservationIgnored private var isReplaying = false
    @ObservationIgnored private var recordingStarted = false
    @ObservationIgnored private var retainedAudio = "none"
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var cancelling = false
    @ObservationIgnored private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var selectedEngine = SpeechEngine.apple
    @ObservationIgnored private var activeLanguageCode = "ko"
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var audioTask: Task<[Float], Error>?
    @ObservationIgnored private var localTranscriptionTask: Task<String, Error>?
    @ObservationIgnored private let localRuntime = LocalSpeechRuntime()
    @ObservationIgnored private var qwenSession: StreamingInferenceSession?

    init(dataDirectory: URL = LocalSpeechModels.dataDirectory) {
        models = LocalSpeechModels(root: dataDirectory.appending(path: "Models/Speech"))
        recordingsFolder = dataDirectory.appendingPathComponent("Recordings")
        let defaults = UserDefaults.standard
        readEngine = SpeechEngine(rawValue: defaults.string(forKey: "speechReadEngine") ?? "") ?? .apple
        questionEngine = SpeechEngine(rawValue: defaults.string(forKey: "speechQuestionEngine") ?? "") ?? .apple
        language = defaults.string(forKey: "speechLanguage") ?? "ko-KR"
        termHintsEnabled = defaults.object(forKey: "speechTermHintsEnabled") as? Bool ?? true
        readModelID = defaults.string(forKey: "speechReadModel") ?? ""
        questionModelID = defaults.string(forKey: "speechQuestionModel") ?? ""
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            let isCritical = pressure?.data.contains(.critical) == true
            Task { @MainActor in
                guard let self else { return }
                if self.mode == .idle { await self.releaseIdleModels() }
                else if isCritical { self.fail("메모리가 부족해 음성 인식을 중지했습니다. 다른 작업을 닫고 다시 시도하세요.", id: self.activeID) }
            }
        }
        pressureSource = pressure
        pressure.resume()
        let saved = ((try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for metadata in saved {
            guard let data = try? Data(contentsOf: metadata), let snapshot = try? JSONDecoder().decode(SpeechRecordingSnapshot.self, from: data),
                  snapshot.fileName == URL(fileURLWithPath: snapshot.fileName).lastPathComponent, snapshot.fileName.hasSuffix(".caf") else { continue }
            let url = recordingsFolder.appendingPathComponent(snapshot.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                lastRecordingURL = url
                lastRecordingDocumentID = snapshot.documentID
                lastRecordingSnapshot = snapshot
                break
            }
        }
    }

    deinit { pressureSource?.cancel() }

    func checkAssets() async {
        guard !Task.isCancelled else { return }
        let id = UUID(), checkedLanguage = language
        assetCheckID = id
        let readStatus = await assetStatus(locale: Locale(identifier: "en-US"))
        guard !Task.isCancelled, assetCheckID == id, language == checkedLanguage else { return }
        let questionStatus = await assetStatus(locale: Locale(identifier: checkedLanguage))
        guard !Task.isCancelled, assetCheckID == id, language == checkedLanguage else { return }
        appleReadStatus = readStatus
        appleQuestionStatus = questionStatus
    }

    func availableModels(for purpose: SpeechMode) -> [LocalSpeechModel] {
        return models.installed.filter { $0.engine == .qwen || (purpose == .question && $0.engine == .whisper) }
    }

    func modelSelection(for purpose: SpeechMode) -> String {
        Self.selectionKey(engine: purpose == .read ? readEngine : questionEngine,
                          modelID: purpose == .read ? readModelID : questionModelID)
    }

    func selectModel(_ selection: String, for purpose: SpeechMode) {
        guard mode == .idle else { return }
        if selection == "apple" {
            if purpose == .read { readEngine = .apple } else { questionEngine = .apple }
        } else if let model = Self.selectedModel(selection, purpose: purpose, installed: availableModels(for: purpose)) {
            if purpose == .read { readModelID = model.id; readEngine = model.engine }
            else { questionModelID = model.id; questionEngine = model.engine }
        }
    }

    static func selectionKey(engine: SpeechEngine, modelID: String) -> String {
        engine == .apple ? "apple" : "\(engine.rawValue):\(modelID)"
    }

    private static func selectedModel(_ selection: String, purpose: SpeechMode, installed: [LocalSpeechModel]) -> LocalSpeechModel? {
        installed.first { ($0.engine == .qwen || (purpose == .question && $0.engine == .whisper)) && selectionKey(engine: $0.engine, modelID: $0.id) == selection }
    }

    func removeModel(_ model: LocalSpeechModel) async {
        guard mode == .idle else { error = "음성 인식을 종료한 뒤 모델을 삭제하세요."; return }
        idleTask?.cancel()
        await localRuntime.unload()
        guard mode == .idle else { error = "모델을 사용 중이므로 삭제하지 않았습니다."; return }
        do { try models.remove(model) }
        catch { self.error = error.localizedDescription }
    }

    /// This explicit settings button can install OS speech assets; microphone actions never download silently.
    func installAppleAssets(for purpose: SpeechMode) async {
        guard !isInstallingAssets else { return }
        isInstallingAssets = true
        error = nil
        defer { isInstallingAssets = false }
        do {
            let transcriber = try await makeTranscriber(locale: locale(for: purpose))
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            await checkAssets()
        } catch { self.error = error.localizedDescription }
    }

    func start(mode purpose: SpeechMode, documentID: UUID? = nil, documentURL: URL? = nil, pageIndex: Int = 0,
               onResult: @escaping (String) -> Void) async {
        guard mode == .idle else { return }
        mode = .preparing
        activeMode = purpose
        partialText = ""
        confirmedText = ""
        correctionTerms = []
        isReplaying = false
        recordingStarted = false
        error = nil
        idleTask?.cancel()
        self.onResult = onResult
        let id = UUID()
        activeID = id
        let selected = purpose == .read ? readEngine : questionEngine
        selectedEngine = selected
        let locale = locale(for: purpose)
        let useTermHints = termHintsEnabled && purpose == .question
        recordingSnapshot = SpeechRecordingSnapshot(fileName: "", purpose: purpose, engine: selected,
                                                    modelID: purpose == .read ? readModelID : questionModelID, language: locale.identifier, documentID: documentID)
        activeLanguageCode = locale.language.languageCode?.identifier ?? "en"
        retainedAudio = UserDefaults.standard.string(forKey: "audioRetention") ?? "none"
        let task = Task { @MainActor [self] in
            do {
                if useTermHints, let documentURL {
                    let terms = await SpeechTermHints.extract(from: documentURL, pageIndex: pageIndex)
                    try Task.checkCancellation()
                    guard self.activeID == id else { return }
                    self.correctionTerms = terms
                }
                self.recordingSnapshot?.correctionTerms = self.correctionTerms
                try await self.requestMicrophonePermission()
                try Task.checkCancellation()
                if selected != .apple {
                    try await self.startLocal(purpose: purpose, selected: selected, locale: locale, id: id)
                    return
                }
                let transcriber = try await self.makeTranscriber(locale: locale)
                guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                    throw SpeechFailure("Apple 음성 자산이 준비되지 않았습니다. 설정 → 음성 인식에서 해당 언어를 다운로드하세요.")
                }
                try await self.reserveAppleAssets(transcriber, id: id)
                let engine = AVAudioEngine()
                let input = engine.inputNode.outputFormat(forBus: 0)
                guard input.sampleRate > 0, input.channelCount > 0 else { throw SpeechFailure("사용할 수 있는 마이크가 없습니다. 입력 장치를 확인하세요.") }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input) else {
                    throw SpeechFailure("이 마이크의 오디오 형식을 변환할 수 없습니다.")
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
                self.analyzer = analyzer
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                guard self.activeID == id else { return }
                let (sequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
                self.recordingURL = try self.makeRecordingURL()
                let capture = try SpeechAudioCapture(inputFormat: input, outputFormat: format, recordingURL: self.recordingURL,
                    receive: { continuation.yield(AnalyzerInput(buffer: $0)) },
                    finish: { continuation.finish() },
                    failure: { [weak self] message in Task { @MainActor in self?.fail(message, id: id) } })
                self.capture = capture
                self.engine = engine
                self.observeApple(transcriber, purpose: purpose, id: id)
                try await analyzer.start(inputSequence: sequence)
                try Task.checkCancellation()
                guard self.activeID == id else { return }
                engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: input) { buffer, _ in capture.enqueue(buffer) }
                self.tapInstalled = true
                engine.prepare()
                try engine.start()
                self.recordingDidStart()
                self.deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.fail("마이크 입력 장치가 변경되었습니다. 입력 장치를 확인하고 다시 시작하세요.", id: id) }
                }
                self.mode = .listening
            } catch {
                guard self.activeID == id else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                await self.cleanUp(succeeded: false)
            }
        }
        preparationTask = task
        await task.value
        if activeID == id { preparationTask = nil }
    }

    func stop() async {
        guard mode == .listening else {
            if mode == .preparing { cancel() }
            return
        }
        let id = activeID
        mode = .transcribing
        stopMicrophone()
        await capture?.finish()
        guard activeID == id else { return }
        do {
            if selectedEngine == .apple {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                await resultTask?.value
            } else {
                try await finishLocal(id: id)
            }
            guard activeID == id else { return }
            if confirmedText.isEmpty { throw SpeechFailure("인식된 말이 없습니다. 마이크 입력을 확인하고 다시 시도하세요.") }
            partialText = confirmedText
            let completed = confirmedText
            let callback = activeMode == .question ? onResult : nil
            await cleanUp(succeeded: true)
            guard activeID == id else { return }
            callback?(completed)
        } catch {
            guard activeID == id else { return }
            self.error = error.localizedDescription
            await cleanUp(succeeded: false)
        }
    }

    func cancel() {
        activeID = UUID() // Also invalidate a result whose successful cleanup is still finishing.
        onResult = nil
        if mode == .idle {
            idleTask?.cancel()
            cancellationTask = Task { await releaseIdleModels() }
            return
        }
        guard mode != .idle, !cancelling else { return }
        cancelling = true
        mode = .transcribing
        let preparation = preparationTask
        let activeAnalyzer = analyzer
        preparation?.cancel()
        capture?.cancel()
        preparationTask = nil
        if qwenSession == nil { resultTask?.cancel() }
        audioTask?.cancel()
        localTranscriptionTask?.cancel()
        stopMicrophone()
        cancellationTask = Task {
            await activeAnalyzer?.cancelAndFinishNow()
            await preparation?.value
            await cleanUp(succeeded: false)
        }
    }

    private func fail(_ message: String, id: UUID) {
        guard activeID == id, mode != .idle else { return }
        error = message
        cancel()
    }

    private func cleanUp(succeeded: Bool) async {
        defer {
            let waiting = cleanupWaiters
            cleanupWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        let id = activeID
        cancelling = true
        stopMicrophone()
        await capture?.finish()
        persistRecording(succeeded: succeeded)
        capture = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        audioTask?.cancel()
        _ = await audioTask?.result
        audioTask = nil
        localTranscriptionTask = nil
        if let qwenSession {
            // Upstream cancel closes events before its decoder exits; stop + drain joins the decoder first.
            await localRuntime.stop(qwenSession)
            await resultTask?.value
            await localRuntime.cancel(qwenSession)
        } else { resultTask?.cancel() }
        resultTask = nil
        qwenSession = nil
        engine = nil
        if !succeeded || activeID != id { await localRuntime.unload() }
        onResult = nil
        activeMode = nil
        mode = .idle
        cancelling = false
        let minutes = UserDefaults.standard.object(forKey: "speechIdleMinutes") as? Int ?? 5
        idleTask = Task {
            if minutes > 0 { try? await Task.sleep(for: .seconds(Double(minutes) * 60)) }
            guard !Task.isCancelled else { return }
            await releaseIdleModels()
        }
    }

    /// Join owned inference and flush retry metadata before AppKit permits termination.
    func shutdown() async {
        cancel()
        await cancellationTask?.value
        if mode != .idle {
            await withCheckedContinuation { cleanupWaiters.append($0) }
        }
        idleTask?.cancel()
        idleTask = nil
        await localRuntime.unload()
    }

    var lastRecordingPurpose: SpeechMode? { lastRecordingSnapshot?.purpose }

    private func recordingDidStart() {
        recordingStarted = true
        lastRecordingURL = nil
        lastRecordingDocumentID = nil
        lastRecordingSnapshot = nil
    }

    private func persistRecording(succeeded: Bool) {
        if let recordingURL {
            let metadata = recordingURL.deletingPathExtension().appendingPathExtension("json")
            // A replay is an existing library source; only LibraryStore can delete it after checking references.
            if !isReplaying && !recordingStarted {
                // Setup can create a file before the microphone starts; it must not replace an older retry.
                try? FileManager.default.removeItem(at: recordingURL)
                try? FileManager.default.removeItem(at: metadata)
            } else if isReplaying || retainedAudio == "all" || (retainedAudio == "failed" && !succeeded)
                || (retainedAudio == "successful" && succeeded) {
                if FileManager.default.fileExists(atPath: recordingURL.path) {
                    lastRecordingURL = recordingURL
                    lastRecordingDocumentID = recordingSnapshot?.documentID
                    lastRecordingSnapshot = recordingSnapshot
                    if let recordingSnapshot, !isReplaying {
                        do { try JSONEncoder().encode(recordingSnapshot).write(to: metadata, options: .atomic) }
                        catch { self.error = "녹음은 보관했지만 재시도 정보를 저장하지 못했습니다. \(error.localizedDescription)" }
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: recordingURL)
                try? FileManager.default.removeItem(at: metadata)
                if lastRecordingURL == recordingURL { lastRecordingURL = nil; lastRecordingDocumentID = nil; lastRecordingSnapshot = nil }
            }
        }
        recordingURL = nil
        recordingSnapshot = nil
        isReplaying = false
        recordingStarted = false
    }

    private func releaseIdleModels() async {
        guard mode == .idle else { return }
        let id = activeID
        await SpeechModels.endRetention()
        guard !Task.isCancelled, mode == .idle, activeID == id else { return }
        await localRuntime.unload()
    }

    private func stopMicrophone() {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver); self.deviceObserver = nil }
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        }
    }

    private func makeRecordingURL() throws -> URL? {
        guard retainedAudio != "none" else { return nil }
        let folder = recordingsFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString).caf")
        recordingSnapshot?.fileName = url.lastPathComponent
        return url
    }

    static var recordingsDirectory: URL {
        LocalSpeechModels.dataDirectory.appendingPathComponent("Recordings")
    }
    private func locale(for purpose: SpeechMode) -> Locale { Locale(identifier: purpose == .read ? "en-US" : language) }
    private func makeTranscriber(locale: Locale) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFailure("이 Mac의 Apple 음성 인식이 선택한 언어를 지원하지 않습니다.")
        }
        return SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
    }
    private func reserveAppleAssets(_ transcriber: SpeechTranscriber, id: UUID) async throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
        // Locale reservations outlive a recording; idle cleanup releases model RAM, not installed assets.
        for locale in transcriber.selectedLocales {
            _ = try await AssetInventory.reserve(locale: locale)
            try Task.checkCancellation()
            guard activeID == id else { throw CancellationError() }
        }
    }
    private func assetStatus(locale: Locale) async -> String {
        guard let transcriber = try? await makeTranscriber(locale: locale) else { return "지원하지 않음" }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return "준비됨"
        case .downloading: return "다운로드 중"
        case .supported: return "다운로드 필요"
        case .unsupported: return "지원하지 않음"
        @unknown default: return "확인 필요"
        }
    }
    private func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeechFailure("마이크 권한이 거부되었습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 허용하세요.") }
        case .denied, .restricted: throw SpeechFailure("마이크를 사용할 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크를 확인하세요.")
        @unknown default: throw SpeechFailure("마이크 권한을 확인할 수 없습니다.")
        }
    }
    private static func join(_ prefix: String, _ text: String) -> String { [prefix, text].filter { !$0.isEmpty }.joined(separator: " ") }

    private func observeApple(_ transcriber: SpeechTranscriber, purpose: SpeechMode, id: UUID) {
        resultTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.activeID == id, !Task.isCancelled else { break }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self.confirmedText = Self.join(self.confirmedText, text)
                        self.partialText = self.confirmedText
                        if purpose == .read && !text.isEmpty { self.onResult?(text) }
                    } else { self.partialText = Self.join(self.confirmedText, text) }
                }
            } catch {
                if !Task.isCancelled { self?.fail(error.localizedDescription, id: id) }
            }
        }
    }

    func retryLastRecording(onResult: @escaping (String) -> Void) async {
        guard mode == .idle, let url = lastRecordingURL, let snapshot = lastRecordingSnapshot else { return }
        mode = .preparing
        activeMode = snapshot.purpose
        selectedEngine = snapshot.engine
        activeLanguageCode = Locale(identifier: snapshot.language).language.languageCode?.identifier ?? "en"
        retainedAudio = UserDefaults.standard.string(forKey: "audioRetention") ?? "failed"
        recordingURL = url
        recordingSnapshot = snapshot
        correctionTerms = snapshot.correctionTerms ?? []
        isReplaying = true
        confirmedText = ""
        partialText = ""
        error = nil
        idleTask?.cancel()
        let id = UUID()
        activeID = id
        let task = Task { @MainActor [self] in
            do {
                let file = try AVAudioFile(forReading: url)
                if snapshot.engine == .apple {
                    let transcriber = try await makeTranscriber(locale: Locale(identifier: snapshot.language))
                    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                        throw SpeechFailure("이 녹음의 Apple 음성 자산이 준비되지 않았습니다. 설정에서 다운로드하세요.")
                    }
                    try await reserveAppleAssets(transcriber, id: id)
                    let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
                    self.analyzer = analyzer
                    observeApple(transcriber, purpose: .question, id: id)
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                    try Task.checkCancellation()
                    guard activeID == id else { return }
                    mode = .transcribing
                    await resultTask?.value
                } else {
                    try await retryLocalFile(url, snapshot: snapshot, id: id)
                }
                try Task.checkCancellation()
                guard activeID == id else { return }
                let text = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw SpeechFailure("녹음에서 인식된 말이 없습니다.") }
                partialText = text
                await cleanUp(succeeded: true)
                guard activeID == id else { return }
                onResult(text)
            } catch {
                guard activeID == id else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                await cleanUp(succeeded: false)
            }
        }
        preparationTask = task
        await task.value
        if activeID == id { preparationTask = nil }
    }

    private func startLocal(purpose: SpeechMode, selected: SpeechEngine, locale: Locale, id: UUID) async throws {
        guard !(purpose == .read && selected == .whisper) else { throw SpeechFailure("Whisper는 질문 녹음의 파일 인식에 사용할 수 있습니다. 읽기에는 Apple 또는 Qwen을 선택하세요.") }
        let modelID = purpose == .read ? readModelID : questionModelID
        guard let model = models.installed.first(where: { $0.id == modelID && $0.engine == selected }) else {
            throw SpeechFailure("선택한 음성 모델이 설치되어 있지 않습니다. 설정 → 음성 모델에서 다운로드하세요.")
        }
        let spokenLanguage = locale.language.languageCode?.identifier == "ko" ? "Korean" : "English"
        if selected == .qwen {
            qwenSession = try await localRuntime.qwenSession(directory: models.directory(for: model), language: spokenLanguage)
        } else { try await localRuntime.prepareWhisper(directory: models.directory(for: model)) }
        try Task.checkCancellation()
        guard activeID == id else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
            throw SpeechFailure("사용할 수 있는 마이크가 없습니다. 입력 장치를 확인하세요.")
        }
        recordingURL = try makeRecordingURL()
        let capture = try makeLocalCapture(input: input, output: output, recordingURL: recordingURL, purpose: purpose, id: id)
        self.capture = capture
        self.engine = engine
        engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: input) { buffer, _ in capture.enqueue(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        recordingDidStart()
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fail("마이크 입력 장치가 변경되었습니다. 다시 시작하세요.", id: id) }
        }
        mode = .listening
    }

    private func makeLocalCapture(input: AVAudioFormat, output: AVAudioFormat, recordingURL: URL?,
                                  purpose: SpeechMode, id: UUID) throws -> SpeechAudioCapture {
        let (sequence, continuation) = AsyncStream.makeStream(of: [Float].self)
        let capture = try SpeechAudioCapture(inputFormat: input, outputFormat: output, recordingURL: recordingURL,
            receive: { buffer in
                guard let samples = buffer.floatChannelData?[0] else { return }
                continuation.yield(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
            }, finish: { continuation.finish() },
            failure: { [weak self] message in Task { @MainActor in self?.fail(message, id: id) } })
        let session = qwenSession
        let runtime = localRuntime
        audioTask = Task { try await runtime.consume(sequence, session: session) }
        if let session {
            resultTask = Task { @MainActor [weak self] in
                for await event in session.events {
                    guard let self else { break }
                    // A cancelled UI request still drains Qwen until stop has finished its inference task.
                    guard self.activeID == id, !Task.isCancelled else { continue }
                    switch event {
                    case .confirmed(let text): self.acceptLocalConfirmed(text, purpose: purpose)
                    case .provisional(let text): self.partialText = Self.join(self.confirmedText, text)
                    case .displayUpdate(let confirmed, let provisional):
                        self.acceptLocalConfirmed(confirmed, purpose: purpose)
                        self.partialText = Self.join(confirmed, provisional)
                    case .ended(let text): self.acceptLocalConfirmed(text, purpose: purpose)
                    case .stats: break
                    }
                }
            }
        }
        return capture
    }

    private func retryLocalFile(_ url: URL, snapshot: SpeechRecordingSnapshot, id: UUID) async throws {
        guard let model = models.installed.first(where: { $0.id == snapshot.modelID && $0.engine == snapshot.engine }) else {
            throw SpeechFailure("이 녹음에 사용한 음성 모델이 설치되어 있지 않습니다. 같은 모델을 먼저 다운로드하세요.")
        }
        if snapshot.engine == .qwen {
            qwenSession = try await localRuntime.qwenSession(directory: models.directory(for: model), language: snapshot.language.hasPrefix("ko") ? "Korean" : "English")
        } else { try await localRuntime.prepareWhisper(directory: models.directory(for: model)) }
        try Task.checkCancellation()
        guard activeID == id else { return }
        let file = try AVAudioFile(forReading: url)
        guard let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else { throw SpeechFailure("녹음 형식을 읽을 수 없습니다.") }
        capture = try makeLocalCapture(input: file.processingFormat, output: output, recordingURL: nil, purpose: .question, id: id)
        mode = .transcribing
        try await capture?.readFile(url)
        await capture?.finish()
        try Task.checkCancellation()
        guard activeID == id else { return }
        try await finishLocal(id: id)
    }

    private func finishLocal(id: UUID) async throws {
        let samples = try await audioTask?.value ?? []
        guard activeID == id else { throw CancellationError() }
        if let qwenSession {
            await localRuntime.stop(qwenSession)
            await resultTask?.value
        } else {
            let languageCode = activeLanguageCode
            let runtime = localRuntime
            let task = Task { try await runtime.transcribeWhisper(samples: samples, language: languageCode) }
            localTranscriptionTask = task
            let text = try await task.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard activeID == id else { throw CancellationError() }
            confirmedText = text
        }
    }

    private func acceptLocalConfirmed(_ text: String, purpose: SpeechMode) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if purpose == .read, text.hasPrefix(confirmedText) {
            let added = String(text.dropFirst(confirmedText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !added.isEmpty { onResult?(added) }
        }
        confirmedText = text
        partialText = text
    }

}
