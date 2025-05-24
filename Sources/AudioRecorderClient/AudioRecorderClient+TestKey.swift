import Dependencies
import Foundation
import XCTestDynamicOverlay

extension AudioRecorderClient: TestDependencyKey {
    public static var previewValue: Self {
        let isRecording = ActorIsolated(false)
        let currentTime = ActorIsolated(0.0)

        return Self(
            currentTime: { await currentTime.value },
            requestRecordPermission: { true },
            startRecording: { _, _, _ in
                await isRecording.setValue(true)
                while await isRecording.value {
                    try await Task.sleep(for: .seconds(1))
                    await currentTime.withValue { $0 += 1 }
                }
                return true
            },
            pauseRecording: { await isRecording.setValue(false) },
            resumeRecording: { await isRecording.setValue(true) },
            stopRecording: {
                await isRecording.setValue(false)
                await currentTime.setValue(0)
            },
            getAvailableMicrophones: {
                return [
                    Microphone(id: "1", name: "Built-in Microphone"),
                    Microphone(id: "2", name: "External Microphone")
                ]
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
        stopRecording: unimplemented("\(Self.self).stopRecording"),
        getAvailableMicrophones: unimplemented("\(Self.self).getAvailableMicrophones", placeholder: [])
    )
}
