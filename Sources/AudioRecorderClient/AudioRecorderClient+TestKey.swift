import Dependencies
import Foundation
import XCTestDynamicOverlay

extension AudioRecorderClient: TestDependencyKey {
    public static var previewValue: Self {
        let isRecording = LockIsolated(false)
        let currentTime = LockIsolated(0.0)

        return Self(
            currentTime: { currentTime.value },
            requestRecordPermission: { true },
            startRecording: { _, onRecordingStart in
                isRecording.setValue(true)
                onRecordingStart?()
                while isRecording.value {
                    try await Task.sleep(for: .seconds(1))
                    currentTime.withValue { $0 += 1 }
                }
                return true
            },
            pauseRecording: { isRecording.setValue(false) },
            resumeRecording: { isRecording.setValue(true) },
            stopRecording: {
                isRecording.setValue(false)
                currentTime.setValue(0)
            }
        )
    }

    public static let testValue = Self(
        currentTime: unimplemented("\(Self.self).currentTime", placeholder: nil),
        requestRecordPermission: unimplemented(
            "\(Self.self).requestRecordPermission", placeholder: false
        ),
        startRecording: unimplemented("\(Self.self).startRecording", placeholder: false),
        pauseRecording: unimplemented("\(Self.self).pauseRecording"),
        resumeRecording: unimplemented("\(Self.self).resumeRecording"),
        stopRecording: unimplemented("\(Self.self).stopRecording")
    )
}
