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
}
