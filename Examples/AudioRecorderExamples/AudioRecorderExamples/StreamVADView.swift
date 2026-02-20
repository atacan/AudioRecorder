//
// https://github.com/atacan
// 02.02.25


import AVFoundation
import AudioRecorderClient
import Dependencies
import Speech
import SwiftUI

@Observable
final class StreamVADModel {
    @ObservationIgnored
    @Dependency(\.date.now) var now
    @ObservationIgnored
    @Dependency(\.audioRecorder) var audioRecorder

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var transcription: String = ""
    var isRecording: Bool = false
    var hasSpeechRecognitionPermission: Bool = false

    init() {
        requestSpeechRecognitionPermission()
    }

    private func requestSpeechRecognitionPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.hasSpeechRecognitionPermission = status == .authorized
            }
        }
    }

    func startButtonTapped() async throws {
        isRecording = true
        transcription = ""

        let stream = try await audioRecorder.live.start(.init(mode: .vad(.init())))

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let recordingsDir = downloadsURL.appendingPathComponent("AudioRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        for try await payload in stream {
            guard case let .vadChunk(samples) = payload else {
                continue
            }

            print("Received chunk with \(samples.count) samples")
            let timestamp = now.formatted(.dateTime.year().month().day().hour().minute().second())
            let filename = "recording_\(timestamp).wav"
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ",", with: "-")
            let fileURL = recordingsDir.appendingPathComponent(filename)

            _ = try saveFloatArrayToWavFile(samples: samples, fileURL: fileURL)
            print("Saved audio file: \(fileURL.path)")

            if hasSpeechRecognitionPermission {
                transcription = "Transcribing..."
                try await processChunkAsSeparateTranscription(samples)
            }
        }

        isRecording = false
    }

    private func processChunkAsSeparateTranscription(_ samples: [Float]) async throws {
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = request

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!

        for (index, sample) in samples.enumerated() {
            pcmBuffer.floatChannelData?[0][index] = sample
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)

        request.append(pcmBuffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            self.recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(
                            throwing: NSError(
                                domain: "SpeechRecognitionError",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Self was deallocated"]
                            )
                        )
                    }
                    return
                }

                if let error = error {
                    if (error as NSError).code != 216 && !hasResumed {
                        self.transcription = "Error: \(error.localizedDescription)"
                        hasResumed = true
                        continuation.resume(throwing: error)
                    } else if !hasResumed {
                        hasResumed = true
                        continuation.resume()
                    }
                    return
                }

                if let result = result, result.isFinal && !hasResumed {
                    self.transcription = result.bestTranscription.formattedString
                    hasResumed = true
                    continuation.resume()
                    return
                }

                if let result = result, !result.isFinal {
                    self.transcription = "Processing: " + result.bestTranscription.formattedString
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if !hasResumed {
                    hasResumed = true
                    self.transcription = "Transcription timed out. The audio may be too quiet or unclear."
                    continuation.resume()
                }
            }
        }
    }

    func stopRecording() {
        Task {
            try? await audioRecorder.live.stop()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
}

struct StreamVADView: View {
    @State var model = StreamVADModel()

    var body: some View {
        VStack(spacing: 20) {
            if !model.hasSpeechRecognitionPermission {
                Text("Speech recognition permission is required for transcription.")
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding()
            }

            if model.isRecording {
                Button {
                    model.stopRecording()
                } label: {
                    Text("Stop")
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            } else {
                Button {
                    Task {
                        do {
                            try await model.startButtonTapped()
                        } catch {
                            print("Error: \(error)")
                        }
                    }
                } label: {
                    Text("Start")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }

            Text("Transcription:")
                .fontWeight(.bold)
                .padding(.top)

            ScrollView {
                Text(model.transcription)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .border(Color.gray.opacity(0.3))
        }
        .padding()
    }
}

#Preview {
    StreamVADView()
}

private func saveFloatArrayToWavFile(
    samples: [Float],
    sampleRate: Double = 16_000,
    fileName: String? = nil,
    fileURL: URL? = nil
) throws -> URL {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!

    for (index, sample) in samples.enumerated() {
        audioBuffer.floatChannelData?[0][index] = sample
    }
    audioBuffer.frameLength = AVAudioFrameCount(samples.count)

    let targetURL: URL
    if let fileURL {
        targetURL = fileURL
    } else {
        let actualFileName = fileName ?? "recording_\(Date().timeIntervalSince1970).wav"
        let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let recordingsDir = downloadsPath.appendingPathComponent("AudioRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        targetURL = recordingsDir.appendingPathComponent(actualFileName)
    }

    try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: targetURL.path) {
        try FileManager.default.removeItem(at: targetURL)
    }

    let audioFile = try AVAudioFile(forWriting: targetURL, settings: format.settings)
    try audioFile.write(from: audioBuffer)
    return targetURL
}
