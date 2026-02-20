import AVFoundation
import Dependencies
import Foundation

public struct AudioRecorderClient: Sendable {
    public var permissions: Permissions
    public var live: Live
    public var file: File

    public init(
        permissions: Permissions,
        live: Live,
        file: File
    ) {
        self.permissions = permissions
        self.live = live
        self.file = file
    }

    public struct Permissions: Sendable {
        public var requestRecordPermission: @Sendable () async -> Bool

        public init(requestRecordPermission: @escaping @Sendable () async -> Bool) {
            self.requestRecordPermission = requestRecordPermission
        }
    }

    public struct Live: Sendable {
        public var start: @Sendable (_ config: LiveStreamConfiguration) async throws -> AsyncThrowingStream<AudioPayload, Error>
        public var pause: @Sendable () async throws -> Void
        public var resume: @Sendable () async throws -> Void
        public var stop: @Sendable () async throws -> Void

        public init(
            start: @escaping @Sendable (_ config: LiveStreamConfiguration) async throws -> AsyncThrowingStream<AudioPayload, Error>,
            pause: @escaping @Sendable () async throws -> Void,
            resume: @escaping @Sendable () async throws -> Void,
            stop: @escaping @Sendable () async throws -> Void
        ) {
            self.start = start
            self.pause = pause
            self.resume = resume
            self.stop = stop
        }
    }

    public struct File: Sendable {
        public var start: @Sendable (_ config: FileRecordingConfiguration) async throws -> Void
        public var currentTime: @Sendable () async -> TimeInterval?
        public var pause: @Sendable () async throws -> Void
        public var resume: @Sendable () async throws -> Void
        public var stop: @Sendable () async throws -> FileRecordingResult

        public init(
            start: @escaping @Sendable (_ config: FileRecordingConfiguration) async throws -> Void,
            currentTime: @escaping @Sendable () async -> TimeInterval?,
            pause: @escaping @Sendable () async throws -> Void,
            resume: @escaping @Sendable () async throws -> Void,
            stop: @escaping @Sendable () async throws -> FileRecordingResult
        ) {
            self.start = start
            self.currentTime = currentTime
            self.pause = pause
            self.resume = resume
            self.stop = stop
        }
    }
}

public struct LiveStreamConfiguration: Sendable {
    public var mode: LiveStreamMode
    public var sampleRate: Double
    public var channelCount: Int
    public var bufferDuration: TimeInterval

    public init(
        mode: LiveStreamMode,
        sampleRate: Double = 16_000,
        channelCount: Int = 1,
        bufferDuration: TimeInterval = 0.1
    ) {
        self.mode = mode
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferDuration = bufferDuration
    }
}

public enum LiveStreamMode: Sendable {
    case pcm16
    case float32
    case vad(VADConfiguration)
}

public enum AudioPayload: Sendable {
    case pcm16(Data)
    case float32([Float])
    case vadChunk([Float])
}

public struct VADConfiguration: Sendable {
    public var silenceThreshold: Float
    public var silenceTimeThreshold: Int
    public var stopBehavior: VADStopBehavior

    public init(
        silenceThreshold: Float = 0.022,
        silenceTimeThreshold: Int = 30,
        stopBehavior: VADStopBehavior = .flushBufferedSpeech
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceTimeThreshold = silenceTimeThreshold
        self.stopBehavior = stopBehavior
    }

    public init(
        silenceThreshold: Float = 0.022,
        silenceTimeThresholdSeconds: Int,
        stopBehavior: VADStopBehavior = .flushBufferedSpeech
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceTimeThreshold = silenceTimeThresholdSeconds * 10
        self.stopBehavior = stopBehavior
    }
}

public enum VADStopBehavior: Sendable {
    case flushBufferedSpeech
    case discardBufferedSpeech
}

public struct FileRecordingConfiguration: Sendable {
    public var url: URL
    public var sampleRate: Double
    public var channelCount: Int

    public init(
        url: URL,
        sampleRate: Double = 16_000,
        channelCount: Int = 1
    ) {
        self.url = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct FileRecordingResult: Sendable {
    public var url: URL
    public var duration: TimeInterval
    public var sampleCount: Int

    public init(url: URL, duration: TimeInterval, sampleCount: Int) {
        self.url = url
        self.duration = duration
        self.sampleCount = sampleCount
    }
}

public enum AudioRecorderClientError: Error, Sendable {
    case sessionAlreadyActive
    case noActiveSession
    case invalidOperationForActiveMode
    case engineStartFailed
    case converterFailed
    case fileWriteFailed
}

extension AudioRecorderClient: DependencyKey {
    public static var liveValue: Self {
        let runtime = AudioRuntimeActor()

        return Self(
            permissions: .init(
                requestRecordPermission: {
                    await AudioRuntimeActor.requestRecordPermission()
                }
            ),
            live: .init(
                start: { config in
                    try await runtime.startLive(config: config)
                },
                pause: {
                    try await runtime.pauseLive()
                },
                resume: {
                    try await runtime.resumeLive()
                },
                stop: {
                    try await runtime.stopLive()
                }
            ),
            file: .init(
                start: { config in
                    try await runtime.startFile(config: config)
                },
                currentTime: {
                    await runtime.fileCurrentTime()
                },
                pause: {
                    try await runtime.pauseFile()
                },
                resume: {
                    try await runtime.resumeFile()
                },
                stop: {
                    try await runtime.stopFile()
                }
            )
        )
    }
}

private actor AudioRuntimeActor {
    private enum SessionKind {
        case live
        case file
    }

    private struct VADState {
        var currentBuffer: [Float] = []
        var isSpeechActive = false
        var silenceCounter = 0
    }

    private struct LiveSession {
        var mode: LiveStreamMode
        var continuation: AsyncThrowingStream<AudioPayload, Error>.Continuation
        var vadState: VADState?
    }

    private struct FileSession {
        var config: FileRecordingConfiguration
        var file: AVAudioFile
        var sampleCount: Int64 = 0
        var terminalError: AudioRecorderClientError?
    }

    private enum SessionState {
        case idle
        case live(LiveSession)
        case file(FileSession)
    }

    private var state: SessionState = .idle
    private var audioEngine: AVAudioEngine?
    private var activeToken: UUID?

    func startLive(config: LiveStreamConfiguration) throws -> AsyncThrowingStream<AudioPayload, Error> {
        guard config.channelCount > 0 else {
            throw AudioRecorderClientError.converterFailed
        }
        guard stateIsIdle else {
            throw AudioRecorderClientError.sessionAlreadyActive
        }

        let token = UUID()
        let (stream, continuation) = makeLiveStream(token: token)
        var session = LiveSession(mode: config.mode, continuation: continuation, vadState: nil)

        if case .vad = config.mode {
            session.vadState = VADState()
        }

        state = .live(session)
        activeToken = token

        do {
            try startCapture(
                sampleRate: config.sampleRate,
                channelCount: config.channelCount,
                bufferDuration: config.bufferDuration,
                token: token
            )
        } catch {
            state = .idle
            activeToken = nil
            continuation.finish(throwing: error)
            throw error
        }

        return stream
    }

    func pauseLive() throws {
        try pause(expected: .live)
    }

    func resumeLive() throws {
        try resume(expected: .live)
    }

    func stopLive() throws {
        guard case .live(let session) = state else {
            if case .idle = state {
                throw AudioRecorderClientError.noActiveSession
            }
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }

        if case let .vad(config) = session.mode,
           config.stopBehavior == .flushBufferedSpeech,
           var vadState = session.vadState,
           let finalChunk = Self.finalizeVADIfNeeded(state: &vadState, config: config)
        {
            session.continuation.yield(.vadChunk(finalChunk))
        }

        session.continuation.finish()
        stopCapture()
        state = .idle
        activeToken = nil
    }

    func startFile(config: FileRecordingConfiguration) throws {
        guard config.channelCount > 0 else {
            throw AudioRecorderClientError.converterFailed
        }
        guard stateIsIdle else {
            throw AudioRecorderClientError.sessionAlreadyActive
        }

        try FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: config.url.path) {
            try FileManager.default.removeItem(at: config.url)
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: config.sampleRate,
            channels: AVAudioChannelCount(config.channelCount)
        ) else {
            throw AudioRecorderClientError.converterFailed
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forWriting: config.url, settings: format.settings)
        } catch {
            throw AudioRecorderClientError.fileWriteFailed
        }

        let token = UUID()
        state = .file(.init(config: config, file: audioFile))
        activeToken = token

        do {
            try startCapture(
                sampleRate: config.sampleRate,
                channelCount: config.channelCount,
                bufferDuration: 0.1,
                token: token
            )
        } catch {
            state = .idle
            activeToken = nil
            throw error
        }
    }

    func pauseFile() throws {
        try pause(expected: .file)
    }

    func resumeFile() throws {
        try resume(expected: .file)
    }

    func stopFile() throws -> FileRecordingResult {
        guard case .file(let session) = state else {
            if case .idle = state {
                throw AudioRecorderClientError.noActiveSession
            }
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }

        stopCapture()
        state = .idle
        activeToken = nil

        if let terminalError = session.terminalError {
            throw terminalError
        }

        let duration = Double(session.sampleCount) / session.config.sampleRate
        return FileRecordingResult(
            url: session.config.url,
            duration: duration,
            sampleCount: Int(session.sampleCount)
        )
    }

    func fileCurrentTime() -> TimeInterval? {
        guard case .file(let session) = state else {
            return nil
        }

        return Double(session.sampleCount) / session.config.sampleRate
    }

    private var stateIsIdle: Bool {
        if case .idle = state {
            return true
        }
        return false
    }

    private func pause(expected: SessionKind) throws {
        switch (expected, state) {
        case (_, .idle):
            throw AudioRecorderClientError.noActiveSession
        case (.live, .live), (.file, .file):
            audioEngine?.pause()
        default:
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }
    }

    private func resume(expected: SessionKind) throws {
        switch (expected, state) {
        case (_, .idle):
            throw AudioRecorderClientError.noActiveSession
        case (.live, .live), (.file, .file):
            do {
                try audioEngine?.start()
            } catch {
                throw AudioRecorderClientError.engineStartFailed
            }
        default:
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }
    }

    private func makeLiveStream(
        token: UUID
    ) -> (
        AsyncThrowingStream<AudioPayload, Error>,
        AsyncThrowingStream<AudioPayload, Error>.Continuation
    ) {
        var continuation: AsyncThrowingStream<AudioPayload, Error>.Continuation!
        let stream = AsyncThrowingStream<AudioPayload, Error> { createdContinuation in
            continuation = createdContinuation
        }

        continuation.onTermination = { [token] _ in
            Task {
                await self.handleLiveStreamTermination(token: token)
            }
        }

        return (stream, continuation)
    }

    private func handleLiveStreamTermination(token: UUID) {
        guard activeToken == token else {
            return
        }
        guard case .live = state else {
            return
        }

        stopCapture()
        state = .idle
        activeToken = nil
    }

    private func startCapture(
        sampleRate: Double,
        channelCount: Int,
        bufferDuration: TimeInterval,
        token: UUID
    ) throws {
        #if !os(macOS)
        try setupAudioSessionForRecording()
        #endif

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw AudioRecorderClientError.converterFailed
        }

        let converter: AVAudioConverter?
        if inputFormat.sampleRate == targetFormat.sampleRate,
           inputFormat.channelCount == targetFormat.channelCount,
           inputFormat.commonFormat == .pcmFormatFloat32
        {
            converter = nil
        } else {
            guard let createdConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioRecorderClientError.converterFailed
            }
            converter = createdConverter
        }

        let frameCount = max(1, Int(inputFormat.sampleRate * bufferDuration))

        inputNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(frameCount),
            format: inputFormat
        ) { [token] buffer, _ in
            do {
                let processedBuffer: AVAudioPCMBuffer
                if let converter {
                    processedBuffer = try Self.resampleBuffer(
                        buffer,
                        with: converter,
                        targetFormat: targetFormat
                    )
                } else {
                    processedBuffer = buffer
                }

                let sampleArray = Self.convertBufferToFloatArray(buffer: processedBuffer)
                guard !sampleArray.isEmpty else {
                    return
                }

                Task {
                    self.consumeBuffer(sampleArray, token: token)
                }
            } catch {
                // Keep tap robust on conversion failure; stop is caller-controlled.
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecorderClientError.engineStartFailed
        }

        self.audioEngine = audioEngine
    }

    private func stopCapture() {
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil
    }

    private func consumeBuffer(_ buffer: [Float], token: UUID) {
        guard activeToken == token else {
            return
        }

        switch state {
        case var .live(session):
            switch session.mode {
            case .pcm16:
                let data = Self.convertFloatToPCM16Data(buffer)
                session.continuation.yield(.pcm16(data))
            case .float32:
                session.continuation.yield(.float32(buffer))
            case let .vad(config):
                var vadState = session.vadState ?? VADState()
                if let chunk = Self.processVADBuffer(buffer, state: &vadState, config: config) {
                    session.continuation.yield(.vadChunk(chunk))
                }
                session.vadState = vadState
            }
            state = .live(session)

        case var .file(session):
            do {
                try Self.appendSamples(
                    buffer,
                    to: session.file,
                    sampleRate: session.config.sampleRate,
                    channelCount: session.config.channelCount
                )
                session.sampleCount += Int64(buffer.count / max(1, session.config.channelCount))
            } catch {
                session.terminalError = .fileWriteFailed
                stopCapture()
            }
            state = .file(session)

        case .idle:
            break
        }
    }

    #if !os(macOS)
    private func setupAudioSessionForRecording() throws {
        #if !os(watchOS)
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        #else
        let options: AVAudioSession.CategoryOptions = .mixWithOthers
        #endif

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, options: options)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioRecorderClientError.engineStartFailed
        }
    }
    #endif

    nonisolated static func requestRecordPermission() async -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }

        return await withCheckedContinuation { continuation in
            #if os(iOS)
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
            #elseif os(macOS)
            continuation.resume(returning: true)
            #else
            continuation.resume(returning: true)
            #endif
        }
    }

    private nonisolated static func resampleBuffer(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioRecorderClientError.converterFailed
        }

        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(
            to: convertedBuffer,
            error: &conversionError,
            withInputFrom: inputBlock
        )

        if status == .error || conversionError != nil {
            throw AudioRecorderClientError.converterFailed
        }

        return convertedBuffer
    }

    private nonisolated static func convertBufferToFloatArray(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channels > 0, frameLength > 0 else {
            return []
        }

        var output = [Float](repeating: 0, count: frameLength * channels)

        for frame in 0..<frameLength {
            let baseIndex = frame * channels
            for channel in 0..<channels {
                output[baseIndex + channel] = channelData[channel][frame]
            }
        }

        return output
    }

    private nonisolated static func convertFloatToPCM16Data(_ samples: [Float]) -> Data {
        var int16Samples: [Int16] = []
        int16Samples.reserveCapacity(samples.count)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            int16Samples.append(scaled.littleEndian)
        }

        return int16Samples.withUnsafeBytes { Data($0) }
    }

    private nonisolated static func appendSamples(
        _ samples: [Float],
        to file: AVAudioFile,
        sampleRate: Double,
        channelCount: Int
    ) throws {
        guard channelCount > 0 else {
            throw AudioRecorderClientError.fileWriteFailed
        }

        let frameCount = samples.count / channelCount
        guard frameCount > 0 else {
            return
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ) else {
            throw AudioRecorderClientError.fileWriteFailed
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AudioRecorderClientError.fileWriteFailed
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            throw AudioRecorderClientError.fileWriteFailed
        }

        for frame in 0..<frameCount {
            let baseIndex = frame * channelCount
            for channel in 0..<channelCount {
                channelData[channel][frame] = samples[baseIndex + channel]
            }
        }

        do {
            try file.write(from: buffer)
        } catch {
            throw AudioRecorderClientError.fileWriteFailed
        }
    }

    private nonisolated static func processVADBuffer(
        _ buffer: [Float],
        state: inout VADState,
        config: VADConfiguration
    ) -> [Float]? {
        let energy = averageEnergy(of: buffer)
        let isCurrentBufferSilent = energy < config.silenceThreshold

        if !state.isSpeechActive {
            if !isCurrentBufferSilent {
                state.isSpeechActive = true
                state.silenceCounter = 0
                state.currentBuffer = buffer
            }
            return nil
        }

        state.currentBuffer.append(contentsOf: buffer)

        if isCurrentBufferSilent {
            state.silenceCounter += 1
            if state.silenceCounter >= config.silenceTimeThreshold {
                let trimmed = trimSilenceFromEnd(
                    state.currentBuffer,
                    silenceThreshold: config.silenceThreshold
                )
                state.currentBuffer = []
                state.isSpeechActive = false
                state.silenceCounter = 0
                return trimmed
            }
        } else {
            state.silenceCounter = 0
        }

        return nil
    }

    private nonisolated static func finalizeVADIfNeeded(
        state: inout VADState,
        config: VADConfiguration
    ) -> [Float]? {
        guard !state.currentBuffer.isEmpty else {
            return nil
        }

        let trimmed = trimSilenceFromEnd(
            state.currentBuffer,
            silenceThreshold: config.silenceThreshold
        )

        state.currentBuffer = []
        state.isSpeechActive = false
        state.silenceCounter = 0

        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func averageEnergy(of signal: [Float]) -> Float {
        guard !signal.isEmpty else {
            return 0
        }

        var sumSquares: Float = 0
        for value in signal {
            sumSquares += value * value
        }

        return sqrt(sumSquares / Float(signal.count))
    }

    private nonisolated static func trimSilenceFromEnd(
        _ buffer: [Float],
        silenceThreshold: Float
    ) -> [Float] {
        guard !buffer.isEmpty else {
            return []
        }

        var endIndex = buffer.count - 1
        let chunkSize = 80
        let minSilenceToKeep = 8_000
        let consecutiveNonSilentChunksNeeded = 4
        let silenceBufferMultiplier = 24
        let maxSilenceToKeep = 12_000

        var nonSilentChunksCount = 0
        var lastSpeechEndIndex = endIndex

        while endIndex >= chunkSize && endIndex > minSilenceToKeep {
            let chunkStart = endIndex - chunkSize + 1
            let chunk = Array(buffer[chunkStart...endIndex])
            let energy = averageEnergy(of: chunk)

            if energy > silenceThreshold {
                nonSilentChunksCount += 1
                lastSpeechEndIndex = endIndex

                if nonSilentChunksCount >= consecutiveNonSilentChunksNeeded {
                    let silenceToAdd = chunkSize * silenceBufferMultiplier
                    let upperBound = min(buffer.count - 1, lastSpeechEndIndex + maxSilenceToKeep)
                    let finalEndIndex = min(lastSpeechEndIndex + silenceToAdd, upperBound)
                    return Array(buffer[0...finalEndIndex])
                }
            } else {
                nonSilentChunksCount = max(0, nonSilentChunksCount - 1)
            }

            endIndex -= chunkSize
        }

        let silenceToKeep = min(minSilenceToKeep, maxSilenceToKeep)
        let finalIndex = min(endIndex + silenceToKeep, buffer.count - 1)
        return Array(buffer[0...finalIndex])
    }
}

extension DependencyValues {
    public var audioRecorder: AudioRecorderClient {
        get { self[AudioRecorderClient.self] }
        set { self[AudioRecorderClient.self] = newValue }
    }
}
