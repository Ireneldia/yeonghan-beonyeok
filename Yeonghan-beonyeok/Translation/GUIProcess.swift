import Foundation
import Darwin
import os

struct GUIProcessResult: Sendable {
    let status: Int32
    let output: String
    let errorOutput: String
}

private enum GUIProcessEvent: Sendable {
    case output(Data), error(Data), outputEnded, errorEnded, ioFailure(Int32)
}

/// One owned child process. No shell, global process lookup, or shared-server termination.
@MainActor
final class GUIProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var deadline: Task<Void, Never>?
    private var terminated = false
    private var timedOut = false
    private var cancelling = false
    private var cancellationTask: Task<Void, Never>?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var ownedProcessGroup: Int32?
    private var errorData = Data()
    private var remainder = Data()
    private var outputEnded = false
    private var errorEnded = false
    private var chunks: AsyncStream<GUIProcessEvent>.Iterator?
    private var continuation: AsyncStream<GUIProcessEvent>.Continuation?
    private let ioQueue = DispatchQueue(label: "org.silverhero.yeonghan.process-io", qos: .userInitiated)
    private let ioGroup = DispatchGroup()
    private var inputChannel: DispatchIO?
    private let ioChannels = OSAllocatedUnfairLock(initialState: (channels: [DispatchIO](), processEnded: false))
    private let pendingOutput = OSAllocatedUnfairLock(initialState: (bytes: 0, overflow: false, closed: false))
    private static let outputLimit = 16 * 1024 * 1024

    static func executable(named name: String) -> URL? {
        searchPaths(in: ProcessInfo.processInfo.environment).filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first(where: isExecutable)
    }

    static func environmentForCLI(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        environment["PATH"] = searchPaths(in: inherited).joined(separator: ":")
        return environment
    }

    private static func searchPaths(in environment: [String: String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (environment["PATH"].map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) } ?? [])
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin",
               "/Applications/Codex.app/Contents/Resources", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin",
               "/Applications/Ollama.app/Contents/Resources"]
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
            && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }


    init(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start(timeout: TimeInterval = 180) throws {
        try Task.checkCancellation()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let stream = AsyncStream<GUIProcessEvent> { continuation = $0 }
        chunks = stream.makeAsyncIterator()
        let sink = continuation!
        let channels = ioChannels
        process.terminationHandler = { [weak self] _ in
            let closing = channels.withLock { state in
                state.processEnded = true
                return state.channels
            }
            for channel in closing { channel.close(flags: .stop) }
            Task { @MainActor in
                guard let self else { return }
                self.terminated = true
                self.deadline?.cancel()
                let waiting = self.exitWaiters
                self.exitWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
        do {
            try process.run()
            let pid = process.processIdentifier
            if pid > 1, getpgid(pid) == pid, getpgrp() != pid { ownedProcessGroup = pid }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
        }
        catch {
            closeStreams()
            throw TranslationFailure("실행 파일을 시작할 수 없습니다: \(process.executableURL?.lastPathComponent ?? "CLI")")
        }
        let budget = pendingOutput, limit = Self.outputLimit
        let inputHandle = input.fileHandleForWriting, group = ioGroup
        group.enter()
        inputChannel = DispatchIO(type: .stream, fileDescriptor: inputHandle.fileDescriptor, queue: ioQueue) { @Sendable _ in
            try? inputHandle.close()
            group.leave()
        }
        register(inputChannel!)
        for (handle, isError) in [(output.fileHandleForReading, false), (errors.fileHandleForReading, true)] {
            let receive: @Sendable (Data) -> Bool = { [weak self] data in
                let accepted = budget.withLock { state in
                    guard !state.closed, !state.overflow else { return false }
                    guard data.count <= limit - state.bytes else { state.overflow = true; return false }
                    state.bytes += data.count
                    return true
                }
                guard accepted else {
                    sink.finish()
                    Task { @MainActor [weak self] in self?.cancel() }
                    return false
                }
                if case .terminated = sink.yield(isError ? .error(data) : .output(data)) {
                    budget.withLock { $0.bytes -= data.count }
                    return false
                }
                return true
            }
            register(Self.readChannel(handle, isError: isError, queue: ioQueue, group: ioGroup, sink: sink, receive: receive))
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, self.process.isRunning else { return }
            self.timedOut = true
            self.cancel()
        }
    }

    private func register(_ channel: DispatchIO) {
        let ended = ioChannels.withLock { state in state.channels.append(channel); return state.processEnded }
        if ended { channel.close(flags: .stop) }
    }

    func send(_ text: String) throws {
        try checkOutputState()
        guard let channel = inputChannel, !terminated, !cancelling else { throw TranslationFailure("CLI 입력이 종료되었습니다") }
        let bytes = Data(text.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let sink = continuation, budget = pendingOutput, child = process
        channel.write(offset: 0, data: bytes, queue: ioQueue) { @Sendable done, _, error in
            if done, error != 0, child.isRunning, !budget.withLock({ $0.closed }) { sink?.yield(.ioFailure(error)) }
        }
    }

    nonisolated private static func readChannel(_ handle: FileHandle, isError: Bool, queue: DispatchQueue, group: DispatchGroup,
                                                sink: AsyncStream<GUIProcessEvent>.Continuation,
                                                receive: @escaping @Sendable (Data) -> Bool) -> DispatchIO {
        let fd = handle.fileDescriptor
        group.enter()
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { @Sendable error in
            defer { try? handle.close(); sink.yield(isError ? .errorEnded : .outputEnded); group.leave() }
            guard error == 0 else { sink.yield(.ioFailure(error)); return }
            // Parent exit ends the stream: drain bytes already present, never wait for future descendant output.
            var remaining: Int32 = 0
            let fionread: UInt = 0x4004667f // Darwin _IOR('f', 127, int), unavailable as a Swift-imported macro.
            guard ioctl(fd, fionread, &remaining) == 0 else { sink.yield(.ioFailure(errno)); return }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { sink.yield(.ioFailure(errno)); return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while remaining > 0 {
                let count = Darwin.read(fd, &buffer, min(buffer.count, Int(remaining)))
                if count > 0 {
                    remaining -= Int32(count)
                    if !receive(Data(buffer.prefix(count))) { break }
                } else if count < 0, errno == EINTR { continue }
                else {
                    if count < 0, errno != EAGAIN { sink.yield(.ioFailure(errno)) }
                    break
                }
            }
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: 65_536)
        channel.read(offset: 0, length: .max, queue: queue) { @Sendable done, data, error in
            if let data, !data.isEmpty, !receive(Data(data)) { channel.close(flags: .stop) }
            if error != 0, error != ECANCELED { sink.yield(.ioFailure(error)) }
            if done { channel.close() }
        }
        return channel
    }

    private func writeInput(_ text: String?) async throws {
        guard let channel = inputChannel else { return }
        guard let text, !text.isEmpty else { channel.close(); return }
        let bytes = Data(text.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let error: Int32 = await withCheckedContinuation { continuation in
            channel.write(offset: 0, data: bytes, queue: ioQueue) { @Sendable done, _, error in
                guard done else { return }
                channel.close()
                continuation.resume(returning: error)
            }
        }
        try checkOutputState()
        if error != 0, !((terminated || !process.isRunning) && (error == ECANCELED || error == EPIPE)) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
    }

    func nextLine() async throws -> String? {
        while true {
            try checkOutputState()
            if let newline = remainder.firstIndex(of: 10) {
                let line = remainder[..<newline]
                remainder.removeSubrange(...newline)
                return String(decoding: line, as: UTF8.self)
            }
            if outputEnded && errorEnded { return nil }
            guard var iterator = chunks else { return nil }
            let event = await iterator.next(isolation: MainActor.shared)
            chunks = iterator
            try checkOutputState()
            if let event {
                switch event {
                case .output(let data):
                    pendingOutput.withLock { $0.bytes -= data.count }
                    remainder.append(data)
                case .error(let data):
                    pendingOutput.withLock { $0.bytes -= data.count }
                    errorData.append(data)
                    if errorData.count > 16_384 { errorData.removeFirst(errorData.count - 16_384) }
                case .outputEnded: outputEnded = true
                case .errorEnded: errorEnded = true
                case .ioFailure(let code): throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
            }
            if event == nil || (outputEnded && errorEnded) {
                if timedOut { throw TranslationFailure("응답 시간이 초과되었습니다. 다시 시도하세요") }
                if !remainder.isEmpty {
                    let line = String(decoding: remainder, as: UTF8.self)
                    remainder.removeAll()
                    return line
                }
                return nil
            }
            guard remainder.count < Self.outputLimit else {
                cancel()
                throw TranslationFailure("CLI 응답이 너무 큽니다")
            }
        }
    }

    private func checkOutputState() throws {
        try Task.checkCancellation()
        if pendingOutput.withLock({ $0.overflow }) { cancel(); throw TranslationFailure("CLI 응답이 너무 큽니다") }
        if timedOut { throw TranslationFailure("응답 시간이 초과되었습니다. 다시 시도하세요") }
    }

    func run(input text: String? = nil, timeout: TimeInterval = 180, onOutput: ((String) -> Void)? = nil) async throws -> GUIProcessResult {
        try start(timeout: timeout)
        do {
            return try await withTaskCancellationHandler {
                try await writeInput(text)
                var outputText = "", hasLine = false
                var byteCount = 0
                while let line = try await nextLine() {
                    byteCount += line.utf8.count + 1
                    guard byteCount < Self.outputLimit else { throw TranslationFailure("CLI 응답이 너무 큽니다") }
                    onOutput?(line)
                    if hasLine { outputText.append("\n") }
                    outputText.append(line); hasLine = true
                }
                await waitForExit()
                try Task.checkCancellation()
                if timedOut { throw TranslationFailure("응답 시간이 초과되었습니다. 다시 시도하세요") }
                await cleanup()
                try Task.checkCancellation()
                return GUIProcessResult(status: process.terminationStatus, output: outputText,
                                        errorOutput: String(decoding: errorData, as: UTF8.self))
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
        } catch {
            await cleanup()
            throw error
        }
    }

    private func waitForExit() async {
        if process.isRunning, !terminated {
            await withCheckedContinuation { exitWaiters.append($0) }
        }
        await cancellationTask?.value
    }

    private static func groupIsRunning(_ group: Int32) -> Bool {
        // A dead descendant can remain as a zombie; kill(group, 0) alone is not an exit barrier.
        guard kill(-group, 0) == 0 else { return false }
        let size = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard size >= 0 else { return kill(-group, 0) == 0 }
        guard size > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 16)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let written = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, capacity) }
        guard written >= 0 else { return kill(-group, 0) == 0 }
        guard written < capacity else { return true }
        for pid in pids.prefix(Int(written) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize {
                if info.pbi_pgid == UInt32(group), info.pbi_status != UInt32(SZOMB) { return true }
            } else if getpgid(pid) == group, kill(pid, 0) == 0 { return true }
        }
        return false
    }

    func cancel() {
        deadline?.cancel()
        pendingOutput.withLock { $0.closed = true }
        continuation?.finish()
        guard !cancelling else { return }
        let group = ownedProcessGroup
        let stillRunning: @MainActor @Sendable () -> Bool = { [process] in
            if let group { return Self.groupIsRunning(group) }
            return process.isRunning
        }
        guard stillRunning() else { return }
        cancelling = true
        if let group { kill(-group, SIGTERM) }
        else { process.terminate() }
        cancellationTask = Task { [process] in
            for _ in 0..<20 {
                guard stillRunning() else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let group { kill(-group, SIGKILL) }
            else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            while stillRunning() { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    func cleanup() async {
        closeStreams()
        await waitForExit()
        await withCheckedContinuation { continuation in
            ioGroup.notify(queue: ioQueue) { @Sendable in continuation.resume() }
        }
        ioChannels.withLock { $0.channels.removeAll() }
        inputChannel = nil
    }

    private func closeStreams() {
        cancel()
        let channels = ioChannels.withLock { $0.channels }
        if channels.isEmpty { try? input.fileHandleForWriting.close() }
        for channel in channels { channel.close(flags: .stop) }
        continuation?.finish()
        chunks = nil; continuation = nil
    }
}
