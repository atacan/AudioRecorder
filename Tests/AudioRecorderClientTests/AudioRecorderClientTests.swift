import Dependencies
import Foundation
import XCTest

@testable import AudioRecorderClient

@MainActor
final class AudioRecorderClientTests: XCTestCase {
    func testPreviewPermissionIsGranted() async {
        let granted = await withDependencies {
            $0.audioRecorder = .previewValue
        } operation: {
            @Dependency(\.audioRecorder) var audioRecorder
            return await audioRecorder.permissions.requestRecordPermission()
        }

        XCTAssertTrue(granted)
    }

    func testLiveStartCanBeOverridden() async throws {
        let payload = try await withDependencies {
            $0.audioRecorder = AudioRecorderClient(
                permissions: .init(requestRecordPermission: { true }),
                live: .init(
                    start: { _ in
                        AsyncThrowingStream { continuation in
                            continuation.yield(.pcm16(Data([0x01, 0x00, 0x02, 0x00])))
                            continuation.finish()
                        }
                    },
                    pause: {},
                    resume: {},
                    stop: {}
                ),
                file: .init(
                    start: { _ in },
                    startStreaming: { _ in
                        AsyncThrowingStream { continuation in
                            continuation.finish()
                        }
                    },
                    currentTime: { nil },
                    pause: {},
                    resume: {},
                    stop: {
                        FileRecordingResult(
                            url: URL(fileURLWithPath: "/tmp/noop.wav"),
                            duration: 0,
                            sampleCount: 0
                        )
                    }
                )
            )
        } operation: {
            @Dependency(\.audioRecorder) var audioRecorder

            let stream = try await audioRecorder.live.start(.init(mode: .pcm16))
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        guard case let .pcm16(data)? = payload else {
            XCTFail("Expected a pcm16 payload")
            return
        }

        XCTAssertEqual(data.count, 4)
    }

    func testFileLifecycleCanBeOverridden() async throws {
        let currentTime = LockIsolated<TimeInterval?>(nil)

        let result = try await withDependencies {
            $0.audioRecorder = AudioRecorderClient(
                permissions: .init(requestRecordPermission: { true }),
                live: .init(
                    start: { _ in AsyncThrowingStream { $0.finish() } },
                    pause: {},
                    resume: {},
                    stop: {}
                ),
                file: .init(
                    start: { _ in
                        currentTime.setValue(1.25)
                    },
                    startStreaming: { _ in
                        currentTime.setValue(1.25)
                        return AsyncThrowingStream { continuation in
                            continuation.yield(Data([0x00, 0x00]))
                            continuation.finish()
                        }
                    },
                    currentTime: {
                        currentTime.value
                    },
                    pause: {},
                    resume: {},
                    stop: {
                        let duration = currentTime.value ?? 0
                        currentTime.setValue(nil)
                        return FileRecordingResult(
                            url: URL(fileURLWithPath: "/tmp/fake.wav"),
                            duration: duration,
                            sampleCount: Int(duration * 16_000)
                        )
                    }
                )
            )
        } operation: {
            @Dependency(\.audioRecorder) var audioRecorder

            try await audioRecorder.file.start(.init(url: URL(fileURLWithPath: "/tmp/fake.wav")))
            let time = await audioRecorder.file.currentTime()
            XCTAssertEqual(time, 1.25)
            return try await audioRecorder.file.stop()
        }

        XCTAssertEqual(result.url.path, "/tmp/fake.wav")
        XCTAssertEqual(result.duration, 1.25)
        XCTAssertEqual(result.sampleCount, 20_000)
    }

    func testLifecycleFileStopConfirmsRelease() async throws {
        let harness = LifecycleHarness()
        let client = makeLifecycleClient(harness)
        let session = try await client.lifecycle.startFile(.init(url: URL(fileURLWithPath: "/tmp/lifecycle.wav")))

        let statusWhileRecording = await client.lifecycle.status()
        XCTAssertEqual(statusWhileRecording, .recording(session))
        let outcome = try await client.lifecycle.stop(session)

        guard case let .released(.file(result)) = outcome else {
            return XCTFail("Expected a released file result")
        }
        XCTAssertEqual(result.url.path, "/tmp/lifecycle.wav")
        let statusAfterStop = await client.lifecycle.status()
        XCTAssertEqual(statusAfterStop, .idle)
    }

    func testLifecycleStopFailureKeepsSessionUnavailableUntilTeardown() async throws {
        let harness = LifecycleHarness(failStop: true)
        let client = makeLifecycleClient(harness)
        let session = try await client.lifecycle.startFile(.init(url: URL(fileURLWithPath: "/tmp/failure.wav")))

        let outcome = try await client.lifecycle.stop(session)
        guard case .releaseUnknown(.engineStartFailed) = outcome else {
            return XCTFail("Expected release to be unknown")
        }
        let statusAfterFailure = await client.lifecycle.status()
        XCTAssertEqual(statusAfterFailure, .releaseUnknown(session))

        do {
            _ = try await client.lifecycle.startFile(.init(url: URL(fileURLWithPath: "/tmp/second.wav")))
            XCTFail("A new recording must not start while release is unknown")
        } catch let error as AudioRecorderClientError {
            XCTAssertEqual(error, .sessionAlreadyActive)
        }

        let teardown = try await client.lifecycle.teardown(session)
        XCTAssertEqual(teardown, .released)
        let statusAfterTeardown = await client.lifecycle.status()
        XCTAssertEqual(statusAfterTeardown, .idle)
        _ = try await client.lifecycle.startFile(.init(url: URL(fileURLWithPath: "/tmp/second.wav")))
    }

    func testLifecycleRepeatedStopIsCoalesced() async throws {
        let harness = LifecycleHarness()
        let client = makeLifecycleClient(harness)
        let session = try await client.lifecycle.startFile(.init(url: URL(fileURLWithPath: "/tmp/coalesced.wav")))

        async let first = client.lifecycle.stop(session)
        async let second = client.lifecycle.stop(session)
        let outcomes = try await [first, second]

        XCTAssertEqual(outcomes.count, 2)
        let stopCalls = await harness.stopCallCount()
        XCTAssertEqual(stopCalls, 1)
        let statusAfterStops = await client.lifecycle.status()
        XCTAssertEqual(statusAfterStops, .idle)
    }

    func testLifecycleStreamingFileStopConfirmsRelease() async throws {
        let harness = LifecycleHarness()
        let client = makeLifecycleClient(harness)
        let recording = try await client.lifecycle.startStreamingFile(.init(url: URL(fileURLWithPath: "/tmp/stream.wav")))

        var iterator = recording.stream.makeAsyncIterator()
        let firstChunk = try await iterator.next()
        XCTAssertEqual(firstChunk, Data([0, 1]))

        let outcome = try await client.lifecycle.stop(recording.session)
        guard case .released(.file) = outcome else {
            return XCTFail("Expected streaming-file release")
        }
        let statusAfterStreamingStop = await client.lifecycle.status()
        XCTAssertEqual(statusAfterStreamingStop, .idle)
    }

    func testLifecycleStartIsRejectedBeforePriorRelease() async throws {
        let harness = LifecycleHarness()
        let client = makeLifecycleClient(harness)
        _ = try await client.lifecycle.startLive(.init(mode: .pcm16))

        do {
            _ = try await client.lifecycle.startStreamingFile(.init(url: URL(fileURLWithPath: "/tmp/blocked.wav")))
            XCTFail("A second session must be rejected")
        } catch let error as AudioRecorderClientError {
            XCTAssertEqual(error, .sessionAlreadyActive)
        }
    }
}

private func makeLifecycleClient(_ harness: LifecycleHarness) -> AudioRecorderClient {
    AudioRecorderClient(
        permissions: .init(requestRecordPermission: { true }),
        live: .init(
            start: { _ in AsyncThrowingStream { $0.finish() } },
            pause: {}, resume: {}, stop: {}
        ),
        file: .init(
            start: { _ in },
            startStreaming: { _ in AsyncThrowingStream { $0.finish() } },
            currentTime: { nil },
            pause: {}, resume: {},
            stop: { .init(url: URL(fileURLWithPath: "/tmp/test.wav"), duration: 0, sampleCount: 0) }
        ),
        lifecycle: .init(
            startLive: { _ in try await harness.startLive() },
            startFile: { config in try await harness.startFile(config) },
            startStreamingFile: { config in try await harness.startStreamingFile(config) },
            currentTime: { _ in nil },
            pause: { _ in }, resume: { _ in },
            stop: { session in try await harness.stop(session) },
            teardown: { session in try await harness.teardown(session) },
            status: { await harness.status() }
        )
    )
}

private actor LifecycleHarness {
    private var lifecycleStatus: RecorderLifecycleStatus = .idle
    private var lastOutcome: (RecordingSession, RecordingStopOutcome)?
    private var stopCalls = 0
    private let failStop: Bool
    private var fileURLs: [UUID: URL] = [:]

    init(failStop: Bool = false) {
        self.failStop = failStop
    }

    func startLive() throws -> LiveRecording {
        try ensureIdle()
        let session = RecordingSession(kind: .live)
        lifecycleStatus = .recording(session)
        return .init(session: session, stream: AsyncThrowingStream { $0.finish() })
    }

    func startFile(_ config: FileRecordingConfiguration) throws -> RecordingSession {
        try ensureIdle()
        let session = RecordingSession(kind: .file)
        lifecycleStatus = .recording(session)
        fileURLs[session.id] = config.url
        return session
    }

    func startStreamingFile(_ config: FileRecordingConfiguration) throws -> StreamingFileRecording {
        try ensureIdle()
        let session = RecordingSession(kind: .streamingFile)
        lifecycleStatus = .recording(session)
        fileURLs[session.id] = config.url
        return .init(session: session, stream: AsyncThrowingStream { continuation in
            continuation.yield(Data([0, 1]))
            continuation.finish()
        })
    }

    func stop(_ session: RecordingSession) throws -> RecordingStopOutcome {
        if let lastOutcome, lastOutcome.0 == session {
            return lastOutcome.1
        }
        guard lifecycleStatus == .recording(session) else {
            throw AudioRecorderClientError.invalidSession
        }

        stopCalls += 1
        if failStop {
            lifecycleStatus = .releaseUnknown(session)
            let outcome: RecordingStopOutcome = .releaseUnknown(.engineStartFailed)
            lastOutcome = (session, outcome)
            return outcome
        }

        lifecycleStatus = .idle
        let outcome: RecordingStopOutcome
        if session.kind == .live {
            outcome = .released(.live)
        } else {
            outcome = .released(.file(.init(
                url: fileURLs[session.id]!, duration: 0, sampleCount: 0
            )))
        }
        lastOutcome = (session, outcome)
        return outcome
    }

    func teardown(_ session: RecordingSession) throws -> RecordingTeardownOutcome {
        guard lifecycleStatus == .releaseUnknown(session) || lifecycleStatus == .recording(session) else {
            throw AudioRecorderClientError.invalidSession
        }
        lifecycleStatus = .idle
        return .released
    }

    func status() -> RecorderLifecycleStatus { lifecycleStatus }
    func stopCallCount() -> Int { stopCalls }

    private func ensureIdle() throws {
        guard lifecycleStatus == .idle else {
            throw AudioRecorderClientError.sessionAlreadyActive
        }
    }
}
