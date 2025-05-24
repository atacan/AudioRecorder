import Dependencies
import Foundation
import XCTestDynamicOverlay
import SystemSoundClient
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Represents an audio input device (microphone)
public struct Microphone: Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Errors that can occur during audio recording
public enum AudioRecorderError: Error, Sendable {
    case invalidMicrophoneID(String)
    case failedToSetMicrophone(Int)
}

public struct AudioRecorderClient {
    public var currentTime: @Sendable () async -> TimeInterval?
    public var requestRecordPermission: @Sendable () async -> Bool
    public var startRecording: @Sendable (URL, Bool, Microphone?) async throws -> Bool
    public var pauseRecording: @Sendable () async -> Void
    public var resumeRecording: @Sendable () async -> Void
    public var stopRecording: @Sendable () async -> Void
    public var getAvailableMicrophones: @Sendable () async -> [Microphone]
}

import AVFoundation

extension AudioRecorderClient: DependencyKey {
    public static var liveValue: Self {
        let audioRecorder = AudioRecorder()
        return Self(
            currentTime: { await audioRecorder.currentTime },
            requestRecordPermission: { await AudioRecorder.requestPermission() },
            startRecording: { url, playSound, microphone in try await audioRecorder.start(url: url, playSound: playSound, microphone: microphone) },
            pauseRecording: { await audioRecorder.pause() },
            resumeRecording: { await audioRecorder.resume() },
            stopRecording: { await audioRecorder.stop() },
            getAvailableMicrophones: { await audioRecorder.getAvailableMicrophones() }
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
        if #available(macOS 14.0, iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withUnsafeContinuation { continuation in
#if os(iOS)
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
#elseif os(macOS)
                continuation.resume(returning: true)
#endif
            }
        }
    }

    private func configureMicrophone(_ microphone: Microphone) async throws {
#if os(macOS)
        // On macOS, we need to set the default input device using CoreAudio
        guard let deviceID = AudioDeviceID(microphone.id) else {
            throw AudioRecorderError.invalidMicrophoneID(microphone.id)
        }
        
        var deviceIDValue = deviceID
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            propertySize,
            &deviceIDValue
        )
        
        guard status == noErr else {
            throw AudioRecorderError.failedToSetMicrophone(Int(status))
        }
#else
        // On iOS, microphone selection would be handled differently
        // For now, we'll just ignore the microphone parameter on iOS
        // In a real implementation, you might use AVAudioSession categories and routing
#endif
    }

    func pause() {
        recorder?.pause()
    }

    func resume() {
        recorder?.record()
    }

    func stop() {
        recorder?.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    func start(url: URL, playSound: Bool = false, microphone: Microphone?) async throws -> Bool {
        stop()

        // Configure microphone if specified
        if let microphone = microphone {
            try await configureMicrophone(microphone)
        }

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
                
                if playSound {
                    @Dependency(\.systemSound) var systemSoundClient
                    systemSoundClient.play(.begin_record)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }

        for try await didFinish in stream {
            return didFinish
        }
        throw CancellationError()
    }

    func getAvailableMicrophones() async -> [Microphone] {
#if os(macOS)
        var microphones: [Microphone] = []
        
        // Get all audio devices
        var propertySize: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        ) == noErr else {
            return microphones
        }
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)
        
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            return microphones
        }
        
        // Filter for input devices and get their names
        for deviceID in deviceIDs {
            // Check if device has input streams
            var streamCountSize: UInt32 = 0
            var inputPropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            guard AudioObjectGetPropertyDataSize(
                deviceID,
                &inputPropertyAddress,
                0,
                nil,
                &streamCountSize
            ) == noErr else {
                continue
            }
            
            let inputStreamCount = streamCountSize / UInt32(MemoryLayout<AudioStreamID>.size)
            guard inputStreamCount > 0 else {
                continue // Skip devices without input streams
            }
            
            // Get device name
            var nameSize: UInt32 = 0
            var namePropertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            guard AudioObjectGetPropertyDataSize(
                deviceID,
                &namePropertyAddress,
                0,
                nil,
                &nameSize
            ) == noErr else {
                continue
            }
            
            let nameBuffer = UnsafeMutableRawPointer.allocate(byteCount: Int(nameSize), alignment: MemoryLayout<UInt8>.alignment)
            defer { nameBuffer.deallocate() }
            
            guard AudioObjectGetPropertyData(
                deviceID,
                &namePropertyAddress,
                0,
                nil,
                &nameSize,
                nameBuffer
            ) == noErr else {
                continue
            }
            
            let deviceNameCF = nameBuffer.load(as: CFString.self)
            let deviceName = deviceNameCF as String
            let microphone = Microphone(id: String(deviceID), name: deviceName)
            microphones.append(microphone)
        }
        
        return microphones
#else
        // On iOS, we would use different APIs to get available audio inputs
        // For now, return an empty array
        return []
#endif
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
