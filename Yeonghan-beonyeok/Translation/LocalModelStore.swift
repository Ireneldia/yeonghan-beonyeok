import Foundation
import Observation
import Metal

struct ModelMemoryFit: Sendable {
    enum Level: Sendable { case green, orange, red, unknown }
    var level: Level = .unknown
    var label = "버전별 확인"
    var note = "버전·양자화를 선택하면 메모리 적합도를 표시합니다"
}

struct LocalModelOption: Identifiable, Sendable {
    let id: String
    var name: String { id }
    var description = ""
    var size: Int64?
    var digest = ""
    var isCloud = false
    var fit = ModelMemoryFit()
}

struct LocalModelDownload: Identifiable, Sendable {
    enum State: Sendable { case downloading, complete, failed, cancelled }
    let id: String
    var state: State = .downloading
    var status = "다운로드 준비 중"
    var completed: Int64 = 0
    var total: Int64 = 0
    var totalKnown = false
    var fraction: Double? { total > 0 ? min(state == .complete ? 1 : 0.99, Double(completed) / Double(total)) : nil }
}

@Observable @MainActor
final class LocalModelStore {
    private(set) var installedModels: [LocalModelOption] = []
    var searchQuery = ""
    private(set) var searchResults: [LocalModelOption] = []
    private(set) var downloads: [LocalModelDownload] = []
    private(set) var status = "Ollama 설치 목록을 확인하세요"
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var isSearching = false
    private(set) var deleting: Set<String> = []
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var reloadID = UUID()
    @ObservationIgnored private let totalMemory = ProcessInfo.processInfo.physicalMemory
    @ObservationIgnored private let metalBudget = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize

    var isDownloading: Bool { downloads.contains { $0.state == .downloading } }
    var memoryDescription: String { "통합 메모리 \(ByteCountFormatter.string(fromByteCount: Int64(totalMemory), countStyle: .memory))" }

    func reload() async {
        let id = UUID(); reloadID = id
        isRefreshing = true
        defer { if reloadID == id { isRefreshing = false } }
        do {
            let installed = try await installedRows()
            let running = (try? await json("/api/ps"))?["models"] as? [[String: Any]] ?? []
            try Task.checkCancellation()
            guard reloadID == id else { return }
            installedModels = installed.map { row in
                var row = row
                let loaded = running.first { $0["digest"] as? String == row.digest && $0["context_length"] as? Int == 8192 }
                let allocated = (loaded?["size"] as? NSNumber)?.int64Value
                let gpu = (loaded?["size_vram"] as? NSNumber)?.int64Value
                row.fit = row.isCloud
                    ? ModelMemoryFit(level: .unknown, label: "로컬 가중치 없음", note: "클라우드 연결은 로컬 메모리 적합도 대상이 아닙니다")
                    : memoryFit(row.size, allocated: allocated, gpu: gpu)
                return row
            }
            error = nil
            status = "설치된 모델 \(installed.count)개"
        } catch {
            if reloadID == id, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func search(query: String) async {
        let id = UUID(); searchID = id
        isSearching = true
        defer { if searchID == id { isSearching = false } }
        do {
            guard query.count <= 100, !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw TranslationFailure("검색어는 100자 이내로 입력하세요")
            }
            var url = URLComponents(string: "https://ollama.com/search")!
            url.queryItems = [URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespacesAndNewlines))]
            let page = try await Self.catalogPage(url.url!)
            try Task.checkCancellation()
            guard searchID == id else { return }
            searchResults = Self.catalogLinks(page).filter { !$0.id.contains(":") }
            error = nil
        } catch {
            if searchID == id, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func modelVariants(name: String) async throws -> [LocalModelOption] {
        guard Self.validOfficialModel(name), !name.contains(":") else { throw TranslationFailure("올바른 공식 모델 이름을 선택하세요") }
        let page = try await Self.catalogPage(URL(string: "https://ollama.com/library/\(name)/tags")!)
        return Self.catalogLinks(page).filter { $0.id.hasPrefix(name + ":") }.map { row in
            var row = row
            row.fit = memoryFit(row.size)
            return row
        }
    }

    func startDownload(tag: String) {
        guard Self.validOfficialModel(tag) else { error = "클라우드 버전을 제외한 올바른 공식 모델 이름을 선택하세요"; return }
        let tag = Self.canonical(tag)
        guard !isDownloading else { error = "다른 모델의 다운로드가 진행 중입니다"; return }
        guard !deleting.contains(tag) else { error = "이 모델을 삭제하고 있습니다"; return }
        downloads.removeAll { $0.id == tag }
        downloads.append(LocalModelDownload(id: tag))
        error = nil
        downloadTasks[tag] = Task {
            defer { self.downloadTasks[tag] = nil }
            do { try await self.pull(tag) }
            catch {
                self.updateDownload(tag) {
                    $0.state = Task.isCancelled ? .cancelled : .failed
                    $0.status = Task.isCancelled
                        ? "앱의 다운로드 연결을 중지했습니다. 서버의 설치 결과는 새로고침으로 확인하세요"
                        : error.localizedDescription
                }
            }
        }
    }

    func cancelDownload(_ tag: String) { downloadTasks[tag]?.cancel() }

    func clearCard(_ tag: String) {
        downloads.removeAll { $0.id == tag && $0.state != .downloading }
    }

    func cancelAllDownloads() {
        for task in downloadTasks.values { task.cancel() }
    }

    func deleteInstalled(_ model: LocalModelOption) async {
        guard installedModels.contains(where: { $0.id == model.id }),
              !deleting.contains(model.id), !downloads.contains(where: { $0.id == model.id && $0.state == .downloading }) else {
            error = "모델 상태가 변경됐습니다. 설치 목록을 새로고침하세요"; return
        }
        deleting.insert(model.id)
        defer { deleting.remove(model.id) }
        do {
            guard (try await installedRows()).contains(where: { $0.id == model.id }) else { throw TranslationFailure("이미 삭제된 모델입니다") }
            _ = try await json("/api/delete", body: ["model": model.id], method: "DELETE", timeout: 30, emptyAllowed: true)
            let remaining = try await installedRows()
            guard !remaining.contains(where: { $0.id == model.id }) else { throw TranslationFailure("삭제 완료를 확인하지 못했습니다. 목록을 새로고침하세요") }
            await reload()
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func pull(_ tag: String) async throws {
        var layers = await manifestLayers(tag)
        try Task.checkCancellation()
        updateDownload(tag) { $0.total = layers.values.reduce(0) { $0 + $1.total }; $0.totalKnown = !layers.isEmpty }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": tag, "stream": true])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranslationFailure("Ollama 다운로드 요청에 실패했습니다") }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count < 1_000_000 else { throw TranslationFailure("다운로드 상태 응답이 너무 큽니다") }
            guard !line.isEmpty else { continue }
            let item = try Self.object(Data(line.utf8))
            if let message = item["error"] as? String { throw TranslationFailure(String(message.prefix(300))) }
            if let digest = item["digest"] as? String {
                let previous = layers[digest] ?? (total: 0, completed: 0)
                let total = max(previous.total, Self.positiveInteger(item["total"]) ?? 0)
                let completed = min(total, max(previous.completed, Self.positiveInteger(item["completed"]) ?? 0))
                layers[digest] = (total, completed)
            }
            let complete = item["status"] as? String == "success"
            updateDownload(tag) {
                $0.status = item["status"] as? String ?? "다운로드 중"
                $0.total = layers.values.reduce(0) { $0 + $1.total }
                $0.completed = layers.values.reduce(0) { $0 + $1.completed }
            }
            if complete {
                updateDownload(tag) { $0.status = "설치 결과 확인 중" }
                let info = try await json("/api/show", body: ["model": tag])
                guard info["remote_model"] == nil, info["remote_host"] == nil else {
                    throw TranslationFailure("클라우드 버전입니다. 로컬 가중치가 있는 버전을 선택하세요")
                }
                guard (try await installedRows()).contains(where: { Self.canonical($0.id) == tag && !$0.isCloud }) else {
                    throw TranslationFailure("다운로드 후 설치된 모델을 확인하지 못했습니다")
                }
                await reload()
                try Task.checkCancellation()
                updateDownload(tag) { $0.state = .complete; $0.status = "설치 완료"; $0.completed = $0.total }
                return
            }
        }
        throw TranslationFailure("완료 확인 전에 다운로드 연결이 끊겼습니다. 다시 시도하세요")
    }

    private func updateDownload(_ id: String, change: (inout LocalModelDownload) -> Void) {
        if let index = downloads.firstIndex(where: { $0.id == id }) { change(&downloads[index]) }
    }

    private func installedRows() async throws -> [LocalModelOption] {
        let result = try await json("/api/tags")
        guard let models = result["models"] as? [[String: Any]] else { throw TranslationFailure("Ollama 설치 목록 형식을 확인할 수 없습니다") }
        return try models.map { row in
            guard let name = row["name"] as? String, !name.isEmpty, name.count < 1024,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let size = Self.positiveInteger(row["size"]) else { throw TranslationFailure("설치된 모델 정보가 올바르지 않습니다") }
            return LocalModelOption(id: name, size: size, digest: row["digest"] as? String ?? "",
                isCloud: Self.isCloud(name) || row["remote_model"] != nil || row["remote_host"] != nil)
        }
    }

    private func manifestLayers(_ tag: String) async -> [String: (total: Int64, completed: Int64)] {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return [:] }
        var request = URLRequest(url: URL(string: "https://registry.ollama.ai/v2/library/\(parts[0])/manifests/\(parts[1])")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000 else { return [:] }
            let manifest = try Self.object(data)
            let rows = (manifest["layers"] as? [[String: Any]] ?? []) + [manifest["config"] as? [String: Any] ?? [:]]
            var result: [String: (total: Int64, completed: Int64)] = [:]
            for row in rows {
                if let digest = row["digest"] as? String, let size = Self.positiveInteger(row["size"]) { result[digest] = (size, 0) }
            }
            return result
        } catch { return [:] }
    }

    private func json(_ path: String, body: [String: Any]? = nil, method: String? = nil, timeout: TimeInterval = 15, emptyAllowed: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434" + path)!)
        request.timeoutInterval = timeout
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw TranslationFailure("Ollama에 연결할 수 없습니다. 실행 상태를 확인하세요")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else { throw TranslationFailure("Ollama 요청에 실패했습니다. 모델 상태를 새로고침하세요") }
        if emptyAllowed && data.isEmpty { return [:] }
        let object = try Self.object(data)
        if let error = object["error"] as? String { throw TranslationFailure(String(error.prefix(300))) }
        return object
    }

    private func memoryFit(_ weights: Int64?, allocated: Int64? = nil, gpu: Int64? = nil) -> ModelMemoryFit {
        guard let weights, weights > 0 else { return ModelMemoryFit() }
        // Jan's public Apple Silicon estimate (Apache-2.0, Menlo Research, 2025):
        // https://github.com/janhq/jan/blob/616ca7210d1350d68a56536d57fd0f23691684a7/web-app/src/lib/modelCompatibility.ts
        // ponytail: 8192-token KV memory is estimated from file size; use measured allocation when available.
        let budget = max(0, Double(totalMemory) * 0.9 - 2.5 * 1_073_741_824)
        let required = allocated.map(Double.init) ?? Double(weights) * 1.2
        var fit = ModelMemoryFit(level: required > budget ? .red : required <= budget * 0.85 ? .green : .orange,
            label: required > budget ? "메모리 부족 예상" : required <= budget * 0.85 ? "쾌적 예상" : "여유 적음",
            note: allocated == nil ? "파일 크기·8192 토큰 문맥 기준 추정" : "같은 모델·문맥의 Ollama 할당량 기준")
        if let allocated, let gpu, gpu < allocated {
            if fit.level == .green { fit.level = .orange; fit.label = "여유 적음" }
            fit.note += " · CPU 사용 또는 GPU 일부 적재"
        }
        if let metalBudget, required > Double(metalBudget) { fit.note += " · Metal 권장 작업량 초과 예상" }
        return fit
    }

    @concurrent private static func catalogPage(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("yeonghan-beonyeok/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranslationFailure("Ollama 공식 모델 목록을 가져오지 못했습니다") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_000_000 else { throw TranslationFailure("공식 모델 목록 응답이 너무 큽니다") }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TranslationFailure("모델 응답 형식이 올바르지 않습니다") }
        return value
    }

    private static func canonical(_ model: String) -> String { model.contains(":") ? model : model + ":latest" }
    private static func isCloud(_ model: String) -> Bool { model.lowercased().hasSuffix(":cloud") || model.lowercased().hasSuffix("-cloud") }
    private static func validOfficialModel(_ model: String) -> Bool {
        model.count <= 200 && !isCloud(model) && model.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*(?::[A-Za-z0-9][A-Za-z0-9_.-]*)?$"#, options: .regularExpression) != nil
    }
    private static func positiveInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue < Double(Int64.max), number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.int64Value
    }

    private static func catalogLinks(_ html: String) -> [LocalModelOption] {
        // ponytail: only official library anchors are parsed; update this selector if Ollama changes its catalog markup.
        let anchors = try! NSRegularExpression(pattern: #"<a\b[^>]*\bhref\s*=\s*["']/library/([A-Za-z0-9][A-Za-z0-9_.:-]*)["'][^>]*>([\s\S]*?)</a>"#, options: .caseInsensitive)
        let text = html as NSString
        var rows: [LocalModelOption] = []
        for match in anchors.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let id = text.substring(with: match.range(at: 1))
            let inner = text.substring(with: match.range(at: 2))
            guard validOfficialModel(id), inner.localizedCaseInsensitiveContains("<h2") || id.contains(":") else { continue }
            let plain = plainText(inner)
            let sizePattern = #"\b\d+(?:\.\d+)?\s*[KMGT]i?B\b"#
            let size = plain.range(of: sizePattern, options: [.regularExpression, .caseInsensitive]).flatMap { sizeBytes(String(plain[$0])) }
            let description: String
            if let p = inner.range(of: #"<p\b[^>]*>([\s\S]*?)</p>"#, options: [.regularExpression, .caseInsensitive]) { description = plainText(String(inner[p])) }
            else { description = "" }
            if let index = rows.firstIndex(where: { $0.id == id }) {
                if !description.isEmpty { rows[index].description = description }
                if let size { rows[index].size = size }
            } else { rows.append(LocalModelOption(id: id, description: description, size: size)) }
        }
        return rows
    }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func sizeBytes(_ value: String) -> Int64? {
        let pattern = try! NSRegularExpression(pattern: #"^\s*(\d+(?:\.\d+)?)\s*([KMGT])?(i?B)?\s*$"#, options: .caseInsensitive)
        let text = value as NSString
        guard let match = pattern.firstMatch(in: value, range: NSRange(location: 0, length: text.length)),
              let count = Double(text.substring(with: match.range(at: 1))) else { return nil }
        let unit = match.range(at: 2).location == NSNotFound ? "" : text.substring(with: match.range(at: 2)).uppercased()
        let exponent = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4][unit] ?? 0
        let number = count * pow(value.lowercased().contains("i") ? 1024 : 1000, Double(exponent))
        guard number > 0, number < Double(Int64.max) else { return nil }
        return Int64(number)
    }

}
