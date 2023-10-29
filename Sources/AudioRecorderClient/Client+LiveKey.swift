import Dependencies
import Foundation
import XCTestDynamicOverlay

public struct AudioRecorderClient {
    public var currentTime: @Sendable () async -> TimeInterval?
    public var requestRecordPermission: @Sendable () async -> Bool
    public var startRecording: @Sendable (URL) async throws -> Bool
    public var stopRecording: @Sendable () async -> Void
}

import AVFoundation

extension AudioRecorderClient: DependencyKey {
    public static var liveValue: Self {
        let audioRecorder = AudioRecorder()
        return Self(
            currentTime: { await audioRecorder.currentTime },
            requestRecordPermission: { await AudioRecorder.requestPermission() },
            startRecording: { url in try await audioRecorder.start(url: url) },
            stopRecording: { await audioRecorder.stop() }
        )
    }
}

private actor AudioRecorder {
    var delegate: Delegate?
    var recorder: AVAudioRecorder?

    var currentTime: TimeInterval? {
        guard let recorder,
              recorder.isRecording
        else {
            return nil
        }
        return recorder.currentTime
    }

    static func requestPermission() async -> Bool {
        await withUnsafeContinuation { continuation in
            #if os(iOS)
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
            #elseif os(macOS)
            continuation.resume(returning: true)
            #endif
        }
    }

    func stop() {
        recorder?.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    func start(url: URL) async throws -> Bool {
        stop()

        let stream = AsyncThrowingStream<Bool, Error> { continuation in
            do {
                self.delegate = Delegate(
                    didFinishRecording: { flag in
                        continuation.yield(flag)
                        continuation.finish()
                        #if os(iOS)
                        try? AVAudioSession.sharedInstance().setActive(false)
                        #endif
                    },
                    encodeErrorDidOccur: { error in
                        continuation.finish(throwing: error)
                        #if os(iOS)
                        try? AVAudioSession.sharedInstance().setActive(false)
                        #endif
                    }
                )
                let recorder = try AVAudioRecorder(
                    url: url,
                    settings: [
                        AVFormatIDKey: Int(kAudioFormatLinearPCM),
                        AVSampleRateKey: 16000.0,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]
                )
                self.recorder = recorder
                recorder.delegate = self.delegate

                continuation.onTermination = { [recorder = UncheckedSendable(recorder)] _ in
                    recorder.wrappedValue.stop()
                }
                #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord, mode: .default, options: .defaultToSpeaker
                )
                try AVAudioSession.sharedInstance().setActive(true)
                #endif
                self.recorder?.record()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        for try await didFinish in stream {
            return didFinish
        }
        throw CancellationError()
    }
}

private final class Delegate: NSObject, AVAudioRecorderDelegate, Sendable {
    let didFinishRecording: @Sendable (Bool) -> Void
    let encodeErrorDidOccur: @Sendable (Error?) -> Void

    init(
        didFinishRecording: @escaping @Sendable (Bool) -> Void,
        encodeErrorDidOccur: @escaping @Sendable (Error?) -> Void
    ) {
        self.didFinishRecording = didFinishRecording
        self.encodeErrorDidOccur = encodeErrorDidOccur
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        didFinishRecording(flag)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        encodeErrorDidOccur(error)
    }
}

extension DependencyValues {
    public var audioRecorder: AudioRecorderClient {
        get { self[AudioRecorderClient.self] }
        set { self[AudioRecorderClient.self] = newValue }
    }
}
