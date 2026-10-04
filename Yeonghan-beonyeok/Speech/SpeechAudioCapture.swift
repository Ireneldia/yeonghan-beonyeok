import AVFoundation
import Synchronization

/// AVAudioEngine owns its tap buffers. Copy them before handing work to the serial conversion queue.
nonisolated final class SpeechAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.yeonghan.speech.audio", qos: .userInitiated)
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let receive: @Sendable (AVAudioPCMBuffer) -> Void
    private let finished: @Sendable () -> Void
    private let failure: @Sendable (String) -> Void
    private var file: AVAudioFile?
    private var isFinished = false
    private let cancelled = Mutex(false)

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat, recordingURL: URL?,
         receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         finish: @escaping @Sendable () -> Void, failure: @escaping @Sendable (String) -> Void) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "SpeechCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "마이크 오디오를 인식 형식으로 변환할 수 없습니다."])
        }
        self.converter = converter
        converter.primeMethod = .none
        self.outputFormat = outputFormat
        self.receive = receive
        self.finished = finish
        self.failure = failure
        if let recordingURL { file = try AVAudioFile(forWriting: recordingURL, settings: inputFormat.settings, commonFormat: inputFormat.commonFormat, interleaved: inputFormat.isInterleaved) }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { failure("마이크 입력을 복사하지 못했습니다."); return }
        let packet = OwnedAudioBuffer(buffer: copy)
        queue.async { [self] in
            guard !isFinished else { return }
            do {
                try file?.write(from: packet.buffer)
                guard !cancelled.withLock({ $0 }) else { return }
                try convert(packet.buffer)
            } catch { failure(error.localizedDescription) }
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !isFinished {
                    isFinished = true
                    if !cancelled.withLock({ $0 }) { flush() }
                    file = nil
                    finished()
                }
                continuation.resume()
            }
        }
    }

    func readFile(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let source = try AVAudioFile(forReading: url)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8_192) else {
                        throw NSError(domain: "SpeechCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "녹음 파일을 읽을 수 없습니다."])
                    }
                    while source.framePosition < source.length {
                        if cancelled.withLock({ $0 }) { throw CancellationError() }
                        try source.read(into: buffer)
                        try convert(buffer)
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cancel() { cancelled.withLock { $0 = true } }

    private func flush() {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { return }
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let error { failure(error.localizedDescription); return }
            if output.frameLength > 0, let copy = Self.copy(output) { receive(copy) }
            if status == .endOfStream || status == .error || output.frameLength == 0 { return }
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) throws {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error else { throw NSError(domain: "SpeechCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "마이크 오디오 변환에 실패했습니다."]) }
        if output.frameLength > 0 { receive(output) }
    }

    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        target.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        for (sourceBuffer, destination) in zip(input, output) {
            guard let from = sourceBuffer.mData, let to = destination.mData else { return nil }
            memcpy(to, from, min(Int(sourceBuffer.mDataByteSize), Int(destination.mDataByteSize)))
        }
        return target
    }

}

nonisolated private struct OwnedAudioBuffer: @unchecked Sendable { let buffer: AVAudioPCMBuffer }
