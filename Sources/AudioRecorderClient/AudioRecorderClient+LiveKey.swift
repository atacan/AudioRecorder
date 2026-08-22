import AVFoundation
import Dependencies
import Foundation

public struct AudioRecorderClient: Sendable {
    public var permissions: Permissions
    public var live: Live
    public var file: File
    /// The handle-based API for callers that must know when recorder resources are released.
    public var lifecycle: Lifecycle

    public init(
        permissions: Permissions,
        live: Live,
        file: File
    ) {
        self.permissions = permissions
        self.live = live
        self.file = file
        self.lifecycle = .unavailable
    }

    public init(
        permissions: Permissions,
        live: Live,
        file: File,
        lifecycle: Lifecycle
    ) {
        self.permissions = permissions
        self.live = live
        self.file = file
        self.lifecycle = lifecycle
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
        public var startStreaming: @Sendable (_ config: FileRecordingConfiguration) async throws -> AsyncThrowingStream<Data, Error>
        public var currentTime: @Sendable () async -> TimeInterval?
        public var pause: @Sendable () async throws -> Void
        public var resume: @Sendable () async throws -> Void
        public var stop: @Sendable () async throws -> FileRecordingResult

        public init(
            start: @escaping @Sendable (_ config: FileRecordingConfiguration) async throws -> Void,
            startStreaming: @escaping @Sendable (_ config: FileRecordingConfiguration) async throws -> AsyncThrowingStream<Data, Error>,
            currentTime: @escaping @Sendable () async -> TimeInterval?,
            pause: @escaping @Sendable () async throws -> Void,
            resume: @escaping @Sendable () async throws -> Void,
            stop: @escaping @Sendable () async throws -> FileRecordingResult
        ) {
            self.start = start
            self.startStreaming = startStreaming
            self.currentTime = currentTime
            self.pause = pause
            self.resume = resume
            self.stop = stop
        }
    }

    /// Lifecycle operations scoped to an individual recording session.
    ///
    /// A new recording may only be started after the previous session reports
    /// `.released` from `stop` or `teardown`.
    ///
    /// A reported release covers resources owned by this client: its audio engine,
    /// input tap, file/stream handles, and (on iOS-family platforms) the audio
    /// session it activated. `AVAudioSession` is process-wide, so this client cannot
    /// prove that another component in the host app is not retaining that session.
    public struct Lifecycle: Sendable {
        public var startLive: @Sendable (_ config: LiveStreamConfiguration) async throws -> LiveRecording
        public var startFile: @Sendable (_ config: FileRecordingConfiguration) async throws -> RecordingSession
        public var startStreamingFile: @Sendable (_ config: FileRecordingConfiguration) async throws -> StreamingFileRecording
        public var currentTime: @Sendable (_ session: RecordingSession) async throws -> TimeInterval?
        public var pause: @Sendable (_ session: RecordingSession) async throws -> Void
        public var resume: @Sendable (_ session: RecordingSession) async throws -> Void
        public var stop: @Sendable (_ session: RecordingSession) async throws -> RecordingStopOutcome
        public var teardown: @Sendable (_ session: RecordingSession) async throws -> RecordingTeardownOutcome
        public var status: @Sendable () async -> RecorderLifecycleStatus

        public init(
            startLive: @escaping @Sendable (_ config: LiveStreamConfiguration) async throws -> LiveRecording,
            startFile: @escaping @Sendable (_ config: FileRecordingConfiguration) async throws -> RecordingSession,
            startStreamingFile: @escaping @Sendable (_ config: FileRecordingConfiguration) async throws -> StreamingFileRecording,
            currentTime: @escaping @Sendable (_ session: RecordingSession) async throws -> TimeInterval?,
            pause: @escaping @Sendable (_ session: RecordingSession) async throws -> Void,
            resume: @escaping @Sendable (_ session: RecordingSession) async throws -> Void,
            stop: @escaping @Sendable (_ session: RecordingSession) async throws -> RecordingStopOutcome,
            teardown: @escaping @Sendable (_ session: RecordingSession) async throws -> RecordingTeardownOutcome,
            status: @escaping @Sendable () async -> RecorderLifecycleStatus
        ) {
            self.startLive = startLive
            self.startFile = startFile
            self.startStreamingFile = startStreamingFile
            self.currentTime = currentTime
            self.pause = pause
            self.resume = resume
            self.stop = stop
            self.teardown = teardown
            self.status = status
        }

        static let unavailable = Self(
            startLive: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            startFile: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            startStreamingFile: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            currentTime: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            pause: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            resume: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            stop: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            teardown: { _ in throw AudioRecorderClientError.lifecycleUnavailable },
            status: { .idle }
        )
    }
}

public enum RecordingSessionKind: Sendable, Hashable {
    case live
    case file
    case streamingFile
}

/// A capability for exactly one recorder session. The runtime validates its ID on every operation.
public struct RecordingSession: Sendable, Hashable {
    public let id: UUID
    public let kind: RecordingSessionKind

    public init(id: UUID = UUID(), kind: RecordingSessionKind) {
        self.id = id
        self.kind = kind
    }
}

public struct LiveRecording: Sendable {
    public let session: RecordingSession
    public let stream: AsyncThrowingStream<AudioPayload, Error>

    public init(session: RecordingSession, stream: AsyncThrowingStream<AudioPayload, Error>) {
        self.session = session
        self.stream = stream
    }
}

public struct StreamingFileRecording: Sendable {
    public let session: RecordingSession
    public let stream: AsyncThrowingStream<Data, Error>

    public init(session: RecordingSession, stream: AsyncThrowingStream<Data, Error>) {
        self.session = session
        self.stream = stream
    }
}

public enum RecorderLifecycleStatus: Sendable, Hashable {
    case idle
    case recording(RecordingSession)
    case stopping(RecordingSession)
    case releaseUnknown(RecordingSession)
}

public enum RecordingStopValue: Sendable {
    case live
    case file(FileRecordingResult)
}

/// The result of a requested graceful stop. It always states whether release is known.
///
/// Do not start another recording after `.releaseUnknown`; call `teardown` for the
/// same session and wait for `.released` first.
public enum RecordingStopOutcome: Sendable {
    case released(RecordingStopValue)
    case releasedWithError(AudioRecorderClientError)
    case releaseUnknown(AudioRecorderClientError)
}

/// The result of forced resource cleanup after an uncertain or cancelled stop.
/// Teardown preserves a partial file; deleting it remains the caller's responsibility.
public enum RecordingTeardownOutcome: Sendable, Equatable {
    case released
    case releaseUnknown(AudioRecorderClientError)
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

public enum AudioRecorderClientError: Error, Sendable, Equatable {
    case sessionAlreadyActive
    case noActiveSession
    case invalidOperationForActiveMode
    case engineStartFailed
    case converterFailed
    case fileWriteFailed
    case lifecycleUnavailable
    case invalidSession
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
                startStreaming: { config in
                    try await runtime.startStreamingFile(config: config)
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
            ),
            lifecycle: .init(
                startLive: { config in try await runtime.startManagedLive(config: config) },
                startFile: { config in try await runtime.startManagedFile(config: config) },
                startStreamingFile: { config in try await runtime.startManagedStreamingFile(config: config) },
                currentTime: { session in try await runtime.currentTime(for: session) },
                pause: { session in try await runtime.pause(session: session) },
                resume: { session in try await runtime.resume(session: session) },
                stop: { session in try await runtime.stop(session: session) },
                teardown: { session in try await runtime.teardown(session: session) },
                status: { await runtime.lifecycleStatus() }
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
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
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
    private var activeSession: RecordingSession?
    private var stoppingSession: RecordingSession?
    private var releaseUnknownSession: RecordingSession?
    private var lastStop: (session: RecordingSession, outcome: RecordingStopOutcome)?

    func startLive(config: LiveStreamConfiguration) throws -> AsyncThrowingStream<AudioPayload, Error> {
        try startManagedLive(config: config).stream
    }

    func startManagedLive(config: LiveStreamConfiguration) throws -> LiveRecording {
        guard config.channelCount > 0 else {
            throw AudioRecorderClientError.converterFailed
        }
        guard stateIsIdle else {
            throw AudioRecorderClientError.sessionAlreadyActive
        }

        let token = UUID()
        let recordingSession = RecordingSession(id: token, kind: .live)
        let (stream, continuation) = makeLiveStream(token: token)
        var session = LiveSession(mode: config.mode, continuation: continuation, vadState: nil)

        if case .vad = config.mode {
            session.vadState = VADState()
        }

        state = .live(session)
        activeToken = token
        activeSession = recordingSession
        lastStop = nil

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
            activeSession = nil
            continuation.finish(throwing: error)
            throw error
        }

        return LiveRecording(session: recordingSession, stream: stream)
    }

    func pauseLive() throws {
        try pause(expected: .live)
    }

    func resumeLive() throws {
        try resume(expected: .live)
    }

    func stopLive() throws {
        guard case .live = state, let activeSession else {
            if case .idle = state {
                throw AudioRecorderClientError.noActiveSession
            }
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }

        let outcome = try stop(session: activeSession)
        switch outcome {
        case .released(.live):
            return
        case .releasedWithError(let error), .releaseUnknown(let error):
            throw error
        case .released(.file):
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }
    }

    func startManagedFile(config: FileRecordingConfiguration) throws -> RecordingSession {
        let session = RecordingSession(kind: .file)
        try startFile(config: config, streamContinuation: nil, token: session.id, recordingSession: session)
        return session
    }

    func startManagedStreamingFile(config: FileRecordingConfiguration) throws -> StreamingFileRecording {
        let session = RecordingSession(kind: .streamingFile)
        let (stream, continuation) = makeFileStream(token: session.id)
        do {
            try startFile(config: config, streamContinuation: continuation, token: session.id, recordingSession: session)
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
        return StreamingFileRecording(session: session, stream: stream)
    }

    func startFile(config: FileRecordingConfiguration) throws {
        _ = try startManagedFile(config: config)
    }

    func startStreamingFile(config: FileRecordingConfiguration) throws -> AsyncThrowingStream<Data, Error> {
        try startManagedStreamingFile(config: config).stream
    }

    private func startFile(
        config: FileRecordingConfiguration,
        streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?,
        token: UUID,
        recordingSession: RecordingSession
    ) throws {
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

        state = .file(.init(config: config, file: audioFile, streamContinuation: streamContinuation))
        activeToken = token
        activeSession = recordingSession
        lastStop = nil

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
            activeSession = nil
            streamContinuation?.finish(throwing: error)
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
        guard case .file = state, let activeSession else {
            if case .idle = state {
                throw AudioRecorderClientError.noActiveSession
            }
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }

        let outcome = try stop(session: activeSession)
        switch outcome {
        case .released(.file(let result)):
            return result
        case .releasedWithError(let error), .releaseUnknown(let error):
            throw error
        case .released(.live):
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }
    }

    func fileCurrentTime() -> TimeInterval? {
        guard case .file(let session) = state else {
            return nil
        }

        return Double(session.sampleCount) / session.config.sampleRate
    }

    func currentTime(for session: RecordingSession) throws -> TimeInterval? {
        try validateActive(session, expected: .file)
        return fileCurrentTime()
    }

    func pause(session: RecordingSession) throws {
        switch session.kind {
        case .live:
            try validateActive(session, expected: .live)
        case .file, .streamingFile:
            try validateActive(session, expected: .file)
        }
        audioEngine?.pause()
    }

    func resume(session: RecordingSession) throws {
        switch session.kind {
        case .live:
            try validateActive(session, expected: .live)
        case .file, .streamingFile:
            try validateActive(session, expected: .file)
        }
        do {
            try audioEngine?.start()
        } catch {
            throw AudioRecorderClientError.engineStartFailed
        }
    }

    func lifecycleStatus() -> RecorderLifecycleStatus {
        if let releaseUnknownSession {
            return .releaseUnknown(releaseUnknownSession)
        }
        if let stoppingSession {
            return .stopping(stoppingSession)
        }
        if let activeSession {
            return .recording(activeSession)
        }
        return .idle
    }

    func stop(session requestedSession: RecordingSession) throws -> RecordingStopOutcome {
        if let lastStop, lastStop.session == requestedSession {
            return lastStop.outcome
        }
        guard activeSession == requestedSession else {
            throw AudioRecorderClientError.invalidSession
        }

        stoppingSession = requestedSession
        defer { stoppingSession = nil }

        let outcome: RecordingStopOutcome
        do {
            switch state {
            case .live(let session):
                if case let .vad(config) = session.mode,
                   config.stopBehavior == .flushBufferedSpeech,
                   var vadState = session.vadState,
                   let finalChunk = Self.finalizeVADIfNeeded(state: &vadState, config: config)
                {
                    session.continuation.yield(.vadChunk(finalChunk))
                }
                session.continuation.finish()
                try stopCapture()
                clearActiveSession()
                outcome = .released(.live)

            case .file(let session):
                try stopCapture()
                session.streamContinuation?.finish()
                clearActiveSession()

                if let terminalError = session.terminalError {
                    outcome = .releasedWithError(terminalError)
                } else {
                    let duration = Double(session.sampleCount) / session.config.sampleRate
                    outcome = .released(.file(.init(
                        url: session.config.url,
                        duration: duration,
                        sampleCount: Int(session.sampleCount)
                    )))
                }

            case .idle:
                throw AudioRecorderClientError.noActiveSession
            }
        } catch let error as AudioRecorderClientError {
            releaseUnknownSession = requestedSession
            outcome = .releaseUnknown(error)
        } catch {
            releaseUnknownSession = requestedSession
            outcome = .releaseUnknown(.engineStartFailed)
        }

        lastStop = (requestedSession, outcome)
        return outcome
    }

    func teardown(session requestedSession: RecordingSession) throws -> RecordingTeardownOutcome {
        if activeSession != requestedSession, releaseUnknownSession != requestedSession {
            throw AudioRecorderClientError.invalidSession
        }

        do {
            switch state {
            case .live(let session):
                session.continuation.finish()
            case .file(let session):
                session.streamContinuation?.finish()
            case .idle:
                break
            }
            try stopCapture()
            clearActiveSession()
            releaseUnknownSession = nil
            return .released
        } catch let error as AudioRecorderClientError {
            releaseUnknownSession = requestedSession
            return .releaseUnknown(error)
        } catch {
            releaseUnknownSession = requestedSession
            return .releaseUnknown(.engineStartFailed)
        }
    }

    private var stateIsIdle: Bool {
        if case .idle = state {
            return releaseUnknownSession == nil
        }
        return false
    }

    private func clearActiveSession() {
        state = .idle
        activeToken = nil
        activeSession = nil
        stoppingSession = nil
        releaseUnknownSession = nil
    }

    private func validateActive(_ session: RecordingSession, expected: SessionKind) throws {
        guard activeSession == session else {
            throw AudioRecorderClientError.invalidSession
        }
        switch (expected, state) {
        case (.live, .live), (.file, .file):
            return
        default:
            throw AudioRecorderClientError.invalidOperationForActiveMode
        }
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

    private func makeFileStream(
        token: UUID
    ) -> (
        AsyncThrowingStream<Data, Error>,
        AsyncThrowingStream<Data, Error>.Continuation
    ) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error> { createdContinuation in
            continuation = createdContinuation
        }

        continuation.onTermination = { [token] _ in
            Task {
                await self.handleFileStreamTermination(token: token)
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

        do {
            try stopCapture()
            clearActiveSession()
        } catch {
            if let activeSession {
                releaseUnknownSession = activeSession
            }
        }
    }

    private func handleFileStreamTermination(token: UUID) {
        guard activeToken == token else {
            return
        }
        guard case .file = state else {
            return
        }

        do {
            try stopCapture()
            clearActiveSession()
        } catch {
            if let activeSession {
                releaseUnknownSession = activeSession
            }
        }
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

    private func stopCapture() throws {
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil

        #if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioRecorderClientError.engineStartFailed
        }
        #endif
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
                session.streamContinuation?.yield(Self.convertFloatToPCM16Data(buffer))
            } catch {
                session.terminalError = .fileWriteFailed
                session.streamContinuation?.finish(throwing: AudioRecorderClientError.fileWriteFailed)
                try? stopCapture()
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
