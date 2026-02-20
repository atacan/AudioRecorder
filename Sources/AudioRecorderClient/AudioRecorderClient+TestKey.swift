import Dependencies
import Foundation
import XCTestDynamicOverlay

extension AudioRecorderClient: TestDependencyKey {
    public static var previewValue: Self {
        let fileCurrentSeconds = LockIsolated<TimeInterval?>(nil)
        let isFileRecording = LockIsolated(false)

        return Self(
            permissions: .init(
                requestRecordPermission: { true }
            ),
            live: .init(
                start: { config in
                    AsyncThrowingStream { continuation in
                        switch config.mode {
                        case .pcm16:
                            continuation.yield(.pcm16(Data([0x00, 0x00, 0x01, 0x00])))
                        case .float32:
                            continuation.yield(.float32([0.1, -0.1, 0.25, -0.25]))
                        case .vad:
                            continuation.yield(.vadChunk([0.1, 0.05, 0.0]))
                        }
                        continuation.finish()
                    }
                },
                pause: {},
                resume: {},
                stop: {}
            ),
            file: .init(
                start: { _ in
                    isFileRecording.setValue(true)
                    fileCurrentSeconds.setValue(0)
                },
                currentTime: {
                    fileCurrentSeconds.value
                },
                pause: {
                    isFileRecording.setValue(false)
                },
                resume: {
                    isFileRecording.setValue(true)
                    fileCurrentSeconds.withValue { current in
                        if current == nil {
                            current = 0
                        }
                    }
                },
                stop: {
                    isFileRecording.setValue(false)
                    let current = fileCurrentSeconds.value ?? 0
                    fileCurrentSeconds.setValue(nil)
                    return FileRecordingResult(
                        url: URL(fileURLWithPath: "/tmp/preview.wav"),
                        duration: current,
                        sampleCount: Int(current * 16_000)
                    )
                }
            )
        )
    }

    public static let testValue = Self(
        permissions: .init(
            requestRecordPermission: unimplemented("\(Self.self).permissions.requestRecordPermission", placeholder: false)
        ),
        live: .init(
            start: unimplemented(
                "\(Self.self).live.start",
                placeholder: AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            ),
            pause: unimplemented("\(Self.self).live.pause"),
            resume: unimplemented("\(Self.self).live.resume"),
            stop: unimplemented("\(Self.self).live.stop")
        ),
        file: .init(
            start: unimplemented("\(Self.self).file.start"),
            currentTime: unimplemented("\(Self.self).file.currentTime", placeholder: nil),
            pause: unimplemented("\(Self.self).file.pause"),
            resume: unimplemented("\(Self.self).file.resume"),
            stop: unimplemented(
                "\(Self.self).file.stop",
                placeholder: FileRecordingResult(
                    url: URL(fileURLWithPath: "/tmp/test.wav"),
                    duration: 0,
                    sampleCount: 0
                )
            )
        )
    )
}
