import Foundation
import Observation
@preconcurrency import MLXAudioSTT
@preconcurrency import MLX

struct LocalSpeechModel: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let engine: SpeechEngine
    var revision: String? = nil
    var size: Int64? = nil
    var variantID: String? = nil
    var variantTitle: String? = nil
}

struct SpeechModelVariant: Identifiable, Sendable {
    let id: String
    let title: String
    let size: Int64
    let model: LocalSpeechModel
    let isDefault: Bool
}

@Observable @MainActor
final class LocalSpeechModels {
    private struct RepositoryInfo: Decodable {
        struct Configuration: Decodable { let model_type: String? }
        struct File: Decodable { let rfilename: String; let size: Int64? }
        let sha: String
        let config: Configuration?
        let siblings: [File]?
    }
    private struct ModelFile { let path: String; let size: Int64 }
    private struct ResolvedVariant { let option: SpeechModelVariant; let files: [ModelFile] }
    private struct WeightIndex: Decodable { let weight_map: [String: String] }

    private(set) var installed: [LocalSpeechModel] = []
    private(set) var interrupted: [LocalSpeechModel] = []
    var searchQuery = ""
    private(set) var searchResults: [LocalSpeechModel] = []
    private(set) var isSearching = false
    private(set) var hasLoadedDiscovery = false
    private(set) var downloadingModel: LocalSpeechModel?
    private(set) var progress = 0.0
    private(set) var totalBytes: Int64?
    private(set) var downloadDetail = ""
    private(set) var error: String?
    private(set) var downloadError: String?
    private(set) var removingInterruptedID: String?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadGeneration: UUID?
    @ObservationIgnored private var activeFileID: UUID?
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private let storageRoot: URL
    init(root: URL = LocalSpeechModels.root) { storageRoot = root; refresh() }

    var installedIDs: Set<String> { Set(installed.map(\.id)) }
    var downloadingID: String? { downloadingModel?.id }
    var managedModels: [LocalSpeechModel] {
        var seen: Set<String> = []
        return ([downloadingModel].compactMap { $0 } + installed + interrupted).filter { seen.insert($0.id).inserted }
    }
    var availableSearchResults: [LocalSpeechModel] {
        let managed = Set(managedModels.map(\.id))
        return searchResults.filter { !managed.contains($0.id) }
    }
    func refresh() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil)) ?? []
        installed = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(".complete")),
                  var model = try? JSONDecoder().decode(LocalSpeechModel.self, from: data), Self.safeRepository(model.id),
                  folder.resolvingSymlinksInPath().path == directory(for: model).resolvingSymlinksInPath().path else { return nil }
            model.size = Self.installedSize(at: folder)
            return model
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        interrupted = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(".pending")),
                  let model = try? JSONDecoder().decode(LocalSpeechModel.self, from: data), Self.safeRepository(model.id),
                  folder.resolvingSymlinksInPath().path == stagingDirectory(for: model).resolvingSymlinksInPath().path, !installedIDs.contains(model.id) else { return nil }
            return model
        }
    }
    func directory(for model: LocalSpeechModel) -> URL { storageRoot.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "~")) }
    private func stagingDirectory(for model: LocalSpeechModel) -> URL { storageRoot.appendingPathComponent(".download-" + model.id.replacingOccurrences(of: "/", with: "~")) }
    static var dataDirectory: URL {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Yeonghan-beonyeok")
    }
    static var root: URL { dataDirectory.appending(path: "Models/Speech") }

    func loadDiscoveryIfNeeded() async {
        guard !hasLoadedDiscovery else { return }
        await search("")
    }

    func search(_ query: String) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        searchID = id
        isSearching = true
        error = nil
        defer { if searchID == id { isSearching = false } }
        do {
            struct Result: Decodable {
                let id: String?
                let info: RepositoryInfo?
                private enum CodingKeys: String, CodingKey { case id }
                init(from decoder: Decoder) throws {
                    let values = try? decoder.container(keyedBy: CodingKeys.self)
                    id = try? values?.decode(String.self, forKey: .id)
                    info = try? RepositoryInfo(from: decoder)
                }
            }
            let queries = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ["Qwen3-ASR", "Whisper"] : [query]
            var results: [Result] = []
            for query in queries {
                var components = URLComponents(string: "https://huggingface.co/api/models")!
                components.queryItems = [.init(name: "search", value: query), .init(name: "pipeline_tag", value: "automatic-speech-recognition"),
                                         .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "10"),
                                         .init(name: "expand[]", value: "config"), .init(name: "expand[]", value: "siblings"), .init(name: "expand[]", value: "sha")]
                let data = try await metadata(at: components.url!)
                guard searchID == id else { return }
                results += try JSONDecoder().decode([Result].self, from: data)
            }
            var compatible: [LocalSpeechModel] = []
            var seen: Set<String> = []
            for result in results {
                guard let repositoryID = result.id, Self.safeRepository(repositoryID),
                      repositoryID.lowercased().contains("qwen3-asr") || repositoryID.lowercased().contains("whisper"),
                      let info = result.info, Self.safeRevision(info.sha),
                      let type = info.config?.model_type, let engine = Self.engine(for: type) else { continue }
                if let files = info.siblings {
                    let paths = files.filter { Self.downloadablePath($0.rfilename) && ($0.size.map(Self.validFileSize) ?? true) }.map(\.rfilename)
                    guard (try? Self.validateModelFiles(paths, engine: engine)) != nil else { continue }
                }
                guard seen.insert(repositoryID).inserted else { continue }
                // Different precisions are alternatives, not parts of one download. The detail view resolves each set.
                compatible.append(LocalSpeechModel(id: repositoryID, title: repositoryID, engine: engine, revision: info.sha))
            }
            try Task.checkCancellation()
            guard searchID == id else { return }
            searchResults = compatible
            hasLoadedDiscovery = true
            if compatible.isEmpty { error = "지원하는 Qwen3 ASR 또는 Whisper 모델을 찾지 못했습니다." }
        } catch {
            guard searchID == id, !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func modelVariants(_ model: LocalSpeechModel) async throws -> [SpeechModelVariant] {
        try await resolvedVariants(model).map(\.option)
    }

    private func resolvedVariants(_ model: LocalSpeechModel) async throws -> [ResolvedVariant] {
        guard Self.safeRepository(model.id), model.revision.map(Self.safeRevision) ?? true else { throw SpeechFailure("모델 주소 또는 버전이 올바르지 않습니다.") }
        let revisionPath = model.revision.map { "/revision/\($0)" } ?? ""
        let info = try JSONDecoder().decode(RepositoryInfo.self, from: await metadata(at: URL(string: "https://huggingface.co/api/models/\(model.id)\(revisionPath)?blobs=true")!))
        guard Self.safeRevision(info.sha), model.revision == nil || model.revision == info.sha,
              let siblings = info.siblings else { throw SpeechFailure("모델 버전의 파일 목록을 확인하지 못했습니다.") }
        let files = siblings.compactMap { file -> ModelFile? in
            guard Self.downloadablePath(file.rfilename), let size = file.size, Self.validFileSize(size) else { return nil }
            return ModelFile(path: file.rfilename, size: size)
        }
        guard Set(files.map(\.path)).count == files.count else { throw SpeechFailure("모델 파일 목록에 중복된 경로가 있습니다.") }
        try Self.validateModelFiles(files.map(\.path), engine: model.engine)
        let base = URL(string: "https://huggingface.co/\(model.id)/resolve/\(info.sha)/")!
        let config = try JSONSerialization.jsonObject(with: await metadata(at: base.appendingPathComponent("config.json"))) as? [String: Any]
        guard let type = config?["model_type"] as? String, Self.engine(for: type) == model.engine else { throw SpeechFailure("모델 설정의 실행 형식이 맞지 않습니다.") }
        let quantized = ["quantization", "quantization_config"].contains { config?[$0] is [String: Any] }
        // The pinned Whisper loader does not construct quantized layers.
        guard model.engine != .whisper || !quantized else { throw SpeechFailure("이 Whisper 실행기는 양자화 가중치를 지원하지 않습니다. FP16 또는 FP32 저장소를 선택하세요.") }
        let shared = files.filter { Self.modelMetadata.contains($0.path) }
        let weights = files.filter { $0.path.hasSuffix(".safetensors") }
        var sets: [(id: String, files: [ModelFile])] = []
        for file in weights where file.path == "model.safetensors" || Self.isSingleVariant(file.path)
            || (weights.count == 1 && !files.contains(where: { Self.isWeightIndex($0.path) }) && !Self.isShard(file.path)) {
            sets.append((file.path, [file]))
        }
        for index in files.filter({ Self.isWeightIndex($0.path) }).sorted(by: { $0.path < $1.path }) {
            let data = try await metadata(at: base.appendingPathComponent(index.path))
            guard let map = try? JSONDecoder().decode(WeightIndex.self, from: data), !map.weight_map.isEmpty else { continue }
            let paths = Set(map.weight_map.values)
            guard paths.allSatisfy({ Self.safeFile($0) && $0.hasSuffix(".safetensors") }) else { continue }
            let shards = weights.filter { paths.contains($0.path) }
            guard shards.count == paths.count else { continue }
            sets.append((index.path, shards + [index]))
        }
        sets.sort { lhs, rhs in
            func rank(_ id: String) -> Int { id == "model.safetensors" ? 0 : id == "model.safetensors.index.json" ? 1 : 2 }
            return rank(lhs.id) == rank(rhs.id) ? lhs.id < rhs.id : rank(lhs.id) < rank(rhs.id)
        }
        var seen: Set<Set<String>> = []
        sets = sets.filter { seen.insert(Set($0.files.filter { $0.path.hasSuffix(".safetensors") }.map(\.path))).inserted }
        if quantized {
            // Every alternative would share this config; a floating-point variant cannot safely reuse quantized layers.
            guard let canonical = sets.first(where: { $0.id == "model.safetensors" || $0.id == "model.safetensors.index.json" }) else {
                throw SpeechFailure("이 양자화 설정에 대응하는 기본 가중치 구성을 찾지 못했습니다.")
            }
            sets = [canonical]
        }
        guard !sets.isEmpty else { throw SpeechFailure("단독으로 실행할 수 있는 가중치 파일이나 완전한 분할 파일 구성을 찾지 못했습니다.") }
        let defaultID = sets[0].id
        return try sets.map { set in
            let selected = (shared + set.files).sorted { $0.path < $1.path }
            guard let size = Self.totalSize(selected.map(\.size)), size > 0 else { throw SpeechFailure("모델 파일 용량을 확인할 수 없습니다.") }
            let title = Self.variantTitle(set.id, isDefault: set.id == defaultID, config: config ?? [:])
            var pinned = model
            pinned.revision = info.sha; pinned.variantID = set.id; pinned.variantTitle = title; pinned.size = size
            return ResolvedVariant(option: SpeechModelVariant(id: set.id, title: title, size: size, model: pinned, isDefault: set.id == defaultID), files: selected)
        }
    }

    private func metadata(at url: URL) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(from: url)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { throw SpeechFailure("모델 정보를 가져오지 못했습니다. 네트워크와 저장소 접근 권한을 확인하세요.") }
        return data
    }

    /// Explicit download button only. Merely choosing an engine never fetches weights.
    func download(_ model: LocalSpeechModel) async {
        guard downloadTask == nil, removingInterruptedID != model.id, !installedIDs.contains(model.id), Self.safeRepository(model.id) else { return }
        downloadingModel = model
        progress = 0
        totalBytes = nil
        downloadDetail = "모델 버전 확인 중"
        downloadError = nil
        let generation = UUID()
        downloadGeneration = generation
        let task = Task { @MainActor [self] in
            let staging = stagingDirectory(for: model)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                _ = try checkedStagingContents(model)
                let pendingURL = staging.appendingPathComponent(".pending")
                var requested = model
                let hasPending = FileManager.default.fileExists(atPath: pendingURL.path)
                if hasPending {
                    let pending = try JSONDecoder().decode(LocalSpeechModel.self, from: Data(contentsOf: pendingURL))
                    guard pending.id == model.id, pending.engine == model.engine,
                          let revision = pending.revision, Self.safeRevision(revision) else { throw SpeechFailure("이전 다운로드의 모델 정보가 맞지 않습니다.") }
                    guard model.revision == nil || model.revision == revision,
                          model.variantID == nil || pending.variantID == nil || model.variantID == pending.variantID else {
                        throw SpeechFailure("중단된 다운로드와 다른 버전입니다. 잔여 파일을 삭제한 뒤 새 버전을 선택하세요.")
                    }
                    requested = pending
                }
                let variants = try await resolvedVariants(requested)
                guard let selected = requested.variantID.flatMap({ id in variants.first { $0.option.id == id } })
                        ?? (requested.variantID == nil ? variants.first(where: { $0.option.isDefault }) : nil) else {
                    throw SpeechFailure("선택한 가중치 버전을 찾을 수 없습니다. 버전을 다시 확인하세요.")
                }
                guard !hasPending || model.variantID == nil || model.variantID == selected.option.id else {
                    throw SpeechFailure("중단된 다운로드와 다른 버전입니다. 잔여 파일을 삭제한 뒤 새 버전을 선택하세요.")
                }
                let pinnedModel = selected.option.model
                let revision = pinnedModel.revision!
                let files = selected.files
                let total = selected.option.size
                try Task.checkCancellation()
                try JSONEncoder().encode(pinnedModel).write(to: pendingURL, options: .atomic)
                try await discardUnselectedFiles(pinnedModel, keeping: Set(files.map(\.path)))
                self.downloadingModel = pinnedModel
                self.totalBytes = total
                let completed = Set(files.filter { Self.hasCompleteFile(staging.appendingPathComponent($0.path), size: $0.size) }.map(\.path))
                var received = files.filter { completed.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size }
                self.progress = Double(received) / Double(total)
                for file in files {
                    try Task.checkCancellation()
                    self.downloadDetail = file.path
                    let target = staging.appendingPathComponent(file.path)
                    if completed.contains(file.path) { continue }
                    let prior = received
                    let fileID = UUID()
                    self.activeFileID = fileID
                    let transfer = SpeechFileDownload { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, self.downloadGeneration == generation, self.activeFileID == fileID else { return }
                            self.progress = max(self.progress, min(1, Double(prior + min(bytes, file.size)) / Double(total)))
                        }
                    }
                    let request = URLRequest(url: URL(string: "https://huggingface.co/\(model.id)/resolve/\(revision)/")!.appendingPathComponent(file.path))
                    let resumeURL = staging.appendingPathComponent(file.path + ".resume")
                    let result: (URL, URLResponse)
                    do {
                        result = try await transfer.download(request, resumeData: try? Data(contentsOf: resumeURL))
                        self.activeFileID = nil
                        try? FileManager.default.removeItem(at: resumeURL)
                    } catch {
                        self.activeFileID = nil
                        if let resume = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                            try? resume.write(to: resumeURL, options: .atomic)
                            self.downloadDetail = "완료 파일과 이어받기 정보를 보존했습니다."
                        } else {
                            try? FileManager.default.removeItem(at: resumeURL)
                            self.downloadDetail = "완료 파일은 보존했습니다. 중단된 파일은 다시 다운로드해야 합니다."
                        }
                        throw error
                    }
                    let (temporary, response) = result
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let status = (response as? HTTPURLResponse)?.statusCode, [200, 206].contains(status) else { throw SpeechFailure("\(file.path) 다운로드에 실패했습니다.") }
                    let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
                    guard size == file.size else { throw SpeechFailure("\(file.path)의 크기가 맞지 않습니다. 다시 다운로드하세요.") }
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.moveItem(at: temporary, to: target)
                    if file.path == "config.json" {
                        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent(file.path))) as? [String: Any]
                        guard let type = config?["model_type"] as? String, Self.engine(for: type) == model.engine else { throw SpeechFailure("다운로드한 모델의 엔진이 선택한 형식과 다릅니다.") }
                    }
                    received += file.size
                    self.progress = Double(received) / Double(total)
                }
                try Task.checkCancellation()
                let config = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent("config.json"))) as? [String: Any]
                guard let type = config?["model_type"] as? String, Self.engine(for: type) == model.engine else { throw SpeechFailure("모델 설정의 실행 형식이 맞지 않습니다.") }
                for index in files where Self.isWeightIndex(index.path) {
                    let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent(index.path))) as? [String: Any]
                    guard let weights = contents?["weight_map"] as? [String: String], !weights.isEmpty, weights.values.allSatisfy({ path in files.contains { $0.path == path && path.hasSuffix(".safetensors") } && FileManager.default.fileExists(atPath: staging.appendingPathComponent(path).path) }) else {
                        throw SpeechFailure("모델의 분할 파일을 모두 받지 못했습니다. 이 저장소의 파일 구성을 확인하세요.")
                    }
                }
                try JSONEncoder().encode(pinnedModel).write(to: staging.appendingPathComponent(".complete"))
                let destination = self.directory(for: model)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw SpeechFailure("이미 모델 폴더가 있어 덮어쓰지 않았습니다. 설치된 모델을 확인하세요.")
                }
                try FileManager.default.moveItem(at: staging, to: destination)
            } catch {
                self.downloadError = (error is CancellationError || (error as? URLError)?.code == .cancelled ? "모델 다운로드를 취소했습니다." : error.localizedDescription) + " " + self.downloadDetail
            }
            self.refresh()
            self.downloadGeneration = nil
            self.activeFileID = nil
            self.downloadingModel = nil
            self.downloadTask = nil
        }
        downloadTask = task
        await task.value
    }
    func cancelDownload() { downloadTask?.cancel() }
    func cancelDownloadAndWait() async {
        let task = downloadTask
        task?.cancel()
        await task?.value
    }
    func remove(_ model: LocalSpeechModel) throws {
        guard downloadingID != model.id else { return }
        try FileManager.default.removeItem(at: directory(for: model))
        refresh()
    }

    func removeInterrupted(_ model: LocalSpeechModel) async {
        guard removingInterruptedID == nil else { return }
        removingInterruptedID = model.id
        downloadError = nil
        defer { removingInterruptedID = nil; refresh() }
        do {
            let pending = try checkedInterruptedFiles(model)
            let resumeData = try pending.files.filter { $0.pathExtension == "resume" }.map { file in
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= 16 * 1_024 * 1_024 else { throw SpeechFailure("이어받기 정보가 올바르지 않아 잔여 파일 삭제를 중단했습니다.") }
                return try Data(contentsOf: file)
            }
            for data in resumeData { await SpeechFileDownload.discardResumeData(data) }
            // A suspended native task owns its system temporary file; never parse resume data into deletion paths.
            let verified = try checkedInterruptedFiles(model)
            try FileManager.default.removeItem(at: verified.directory)
        } catch { downloadError = error.localizedDescription }
    }

    private func checkedInterruptedFiles(_ model: LocalSpeechModel) throws -> (directory: URL, files: [URL]) {
        guard Self.safeRepository(model.id), downloadingID != model.id,
              !installedIDs.contains(model.id), !FileManager.default.fileExists(atPath: directory(for: model).path) else {
            throw SpeechFailure("설치되었거나 다운로드 중인 모델의 파일은 이 동작으로 삭제할 수 없습니다.")
        }
        let checked = try checkedStagingContents(model)
        let folder = checked.directory, files = checked.files
        let pending = try JSONDecoder().decode(LocalSpeechModel.self, from: Data(contentsOf: folder.appendingPathComponent(".pending")))
        guard pending.id == model.id, pending.engine == model.engine, let revision = pending.revision,
              revision.count == 40, revision.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw SpeechFailure("중단된 다운로드 정보가 일치하지 않아 삭제하지 않았습니다.")
        }
        return (folder, files)
    }
    private func checkedStagingContents(_ model: LocalSpeechModel) throws -> (directory: URL, files: [URL]) {
        let folder = stagingDirectory(for: model)
        let root = storageRoot.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              folder.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path else {
            throw SpeechFailure("앱의 다운로드 임시 폴더가 아니거나 심볼릭 링크여서 삭제하지 않았습니다.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for file in files {
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw SpeechFailure("다운로드 폴더에 예상하지 못한 폴더나 심볼릭 링크가 있어 삭제하지 않았습니다.")
            }
        }
        return (folder, files)
    }

    private func discardUnselectedFiles(_ model: LocalSpeechModel, keeping selected: Set<String>) async throws {
        let contents = try checkedStagingContents(model)
        for file in contents.files {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            guard name != ".pending", !selected.contains(name) else { continue }
            if name.hasSuffix(".resume") {
                let original = String(name.dropLast(".resume".count))
                if selected.contains(original) { continue }
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= 16 * 1_024 * 1_024 else { throw SpeechFailure("이어받기 정보가 올바르지 않아 다운로드를 중단했습니다.") }
                await SpeechFileDownload.discardResumeData(try Data(contentsOf: file))
                _ = try checkedStagingContents(model)
            } else if !Self.downloadablePath(name) && name != ".complete" { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private static let modelMetadata: Set<String> = [
        "config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
        "added_tokens.json", "vocab.json", "vocab.txt", "merges.txt", "normalizer.json", "preprocessor_config.json",
        "processor_config.json", "chat_template.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model", "tokenizer.tiktoken"
    ]
    private static func safeRevision(_ value: String) -> Bool { value.count == 40 && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
    private static func validFileSize(_ size: Int64) -> Bool { size >= 0 && size < 30_000_000_000 }
    private static func isWeightIndex(_ path: String) -> Bool {
        path.range(of: #"\.safetensors\.index(?:\.[A-Za-z0-9_-]+)?\.json$"#, options: .regularExpression) != nil
    }
    private static func isSingleVariant(_ path: String) -> Bool {
        path.range(of: #"^model\.(?:fp16|fp32|bf16|float16|float32|bfloat16)\.safetensors$"#, options: .regularExpression) != nil
    }
    private static func isShard(_ path: String) -> Bool {
        path.range(of: #"-[0-9]+-of-[0-9]+\.safetensors$"#, options: .regularExpression) != nil
    }
    private static func variantTitle(_ id: String, isDefault: Bool, config: [String: Any]) -> String {
        let name = id.lowercased()
        for (tokens, title) in [(["fp32", "float32"], "FP32"), (["bf16", "bfloat16"], "BF16"), (["fp16", "float16"], "FP16")] {
            if tokens.contains(where: { name.contains($0) }) { return title }
        }
        if isDefault {
            let quantization = config["quantization"] as? [String: Any] ?? config["quantization_config"] as? [String: Any]
            if let bits = quantization?["bits"] as? Int, bits > 0 { return "\(bits)비트" }
            switch config["torch_dtype"] as? String ?? config["dtype"] as? String {
            case "float16": return "FP16"
            case "float32": return "FP32"
            case "bfloat16": return "BF16"
            default: return "표준 가중치"
            }
        }
        return id
    }

    private static func downloadablePath(_ path: String) -> Bool {
        safeFile(path) && ["json", "safetensors", "txt", "model", "tiktoken"].contains(URL(fileURLWithPath: path).pathExtension)
    }
    private static func validateModelFiles(_ paths: [String], engine: SpeechEngine) throws {
        guard paths.contains(where: { $0.hasSuffix(".safetensors") }), paths.contains("config.json") else {
            throw SpeechFailure("지원하는 safetensors 음성 모델 구성이 아닙니다.")
        }
        guard engine != .whisper || paths.contains("tokenizer.json") else {
            throw SpeechFailure("이 Whisper 저장소에는 tokenizer.json이 없습니다. 전체 tokenizer를 포함한 OpenAI 모델을 선택하세요.")
        }
    }
    private static func totalSize(_ sizes: [Int64]) -> Int64? {
        var total: Int64 = 0
        for size in sizes {
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard size >= 0, !overflow else { return nil }
            total = sum
        }
        return total
    }
    private static func installedSize(at folder: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var readable = true
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
            readable = false
            return false
        }) else { return nil }
        var sizes: [Int64] = []
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let size = values.fileSize else { return nil }
            sizes.append(Int64(size))
        }
        return readable ? totalSize(sizes) : nil
    }
    private static func safeFile(_ path: String) -> Bool { !path.isEmpty && path != "." && path != ".." && !path.contains("/") && !path.contains("\\") }
    private static func hasCompleteFile(_ url: URL, size: Int64) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber else { return false }
        return bytes.int64Value == size
    }
    private static func safeRepository(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) } }
    }
    private static func engine(for type: String) -> SpeechEngine? { type == "qwen3_asr" ? .qwen : type == "whisper" ? .whisper : nil }
}


/// A session delegate on a native download task receives byte callbacks; URLSession's async download wrappers do not.
nonisolated private final class SpeechFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var result: Result<(URL, URLResponse), Error>?
    private var cancelled = false
    private var lastProgressTime: ContinuousClock.Instant?

    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    static func discardResumeData(_ data: Data) async {
        let session = URLSession(configuration: .ephemeral)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let task = session.downloadTask(withResumeData: data) { _, _, _ in continuation.resume() }
            task.cancel() // Never resume: disposal must not contact the download server.
        }
        session.invalidateAndCancel()
    }

    func download(_ request: URLRequest, resumeData: Data? = nil) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
                let shouldCancel = lock.withLock {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return cancelled
                }
                task.resume()
                if shouldCancel { cancel() }
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        let task = lock.withLock {
            cancelled = true
            let active = self.task
            self.task = nil
            return active
        }
        task?.cancel { resumeData in
            var info: [String: Any] = [:]
            if let resumeData { info["NSURLSessionDownloadTaskResumeData"] = resumeData }
            self.finish(.failure(NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue, userInfo: info)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let result: Result<(URL, URLResponse), Error> = Result {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("yeonghan-download-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: file)
            if let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber {
                emitProgress(bytes.int64Value, force: true)
            }
            return (file, response)
        }
        let accepted = lock.withLock {
            guard continuation != nil else { return false }
            self.result = result
            return true
        }
        if !accepted, case .success(let saved) = result { try? FileManager.default.removeItem(at: saved.0) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        emitProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) { emitProgress(fileOffset, force: true) }

    private func emitProgress(_ bytes: Int64, force: Bool = false) {
        let shouldEmit = lock.withLock {
            guard !cancelled, continuation != nil else { return false }
            let now = ContinuousClock().now
            if !force, let lastProgressTime, lastProgressTime.duration(to: now) < .milliseconds(100) { return false }
            lastProgressTime = now
            return true
        }
        if shouldEmit { progress(bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !lock.withLock({ cancelled }) else { return } // Cancellation finishes after native resume data is available.
        finish(error.map { .failure($0) } ?? lock.withLock { result } ?? .failure(URLError(.unknown)))
    }

    private func finish(_ outcome: Result<(URL, URLResponse), Error>) {
        let state = lock.withLock {
            let state = (continuation, session, result)
            continuation = nil
            session = nil
            task = nil
            result = nil
            return state
        }
        if case .failure = outcome, case .success(let saved)? = state.2 { try? FileManager.default.removeItem(at: saved.0) }
        state.0?.resume(with: outcome)
        state.1?.finishTasksAndInvalidate()
    }
}

actor LocalSpeechRuntime {
    private var qwen: Qwen3ASRModel?
    private var whisper: WhisperModel?
    private var loadedDirectory: URL?

    // feedAudio performs synchronous MLX encoding; keep one ordered consumer off the UI actor.
    func consume(_ input: AsyncStream<[Float]>, session: StreamingInferenceSession?) async throws -> [Float] {
        var samples: [Float] = []
        for await chunk in input {
            try Task.checkCancellation()
            if let session { session.feedAudio(samples: chunk) }
            else { samples.append(contentsOf: chunk) }
        }
        try Task.checkCancellation()
        return samples
    }

    func stop(_ session: StreamingInferenceSession) { session.stop() }

    func cancel(_ session: StreamingInferenceSession) { session.cancel() }

    func qwenSession(directory: URL, language: String) async throws -> StreamingInferenceSession {
        try Task.checkCancellation()
        if loadedDirectory != directory || qwen == nil {
            unload()
            qwen = try await Qwen3ASRModel.fromModelDirectory(directory)
            loadedDirectory = directory
        }
        try Task.checkCancellation()
        return StreamingInferenceSession(model: qwen!, config: StreamingConfig(language: language))
    }
    func prepareWhisper(directory: URL) async throws {
        try Task.checkCancellation()
        if loadedDirectory != directory || whisper == nil {
            unload()
            whisper = try await WhisperModel.fromDirectory(directory)
            loadedDirectory = directory
        }
        try Task.checkCancellation()
    }
    func transcribeWhisper(samples: [Float], language: String) throws -> String {
        try Task.checkCancellation()
        guard let whisper else { throw SpeechFailure("Whisper 모델이 준비되지 않았습니다.") }
        // ponytail: upstream file inference is not interruptible; cancellation discards its result, then releases the model.
        let result = whisper.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(language: language)).text
        try Task.checkCancellation()
        return result
    }
    func unload() { qwen = nil; whisper = nil; loadedDirectory = nil; Memory.clearCache() }
}
