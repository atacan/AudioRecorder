//
// https://github.com/atacan
// 02.02.25


import Dependencies
import SwiftUI
import AudioDataStreamClient
import Speech

@Observable
final class StreamVADModel {
    @ObservationIgnored
    @Dependency(\.continuousClock) var clock  // Controllable way to sleep a task
    @ObservationIgnored
    @Dependency(\.date.now) var now           // Controllable way to ask for current date
    @ObservationIgnored
    @Dependency(\.mainQueue) var mainQueue    // Controllable scheduling on main queue
    @ObservationIgnored
    @Dependency(\.uuid) var uuid              // Controllable UUID creation
    @ObservationIgnored
    @Dependency(\.audioProcessor) var audioProcessor
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
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
        
        let stream = audioProcessor.startRecording(.init())
        
        // Create a directory for our recordings if it doesn't exist
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let recordingsDir = downloadsURL.appendingPathComponent("AudioRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        
        for try await chunk in stream {
            print("Received chunk with \(chunk.floats.count) samples")
            let timestamp = now.formatted(.dateTime.year().month().day().hour().minute().second())
            let filename = "recording_\(timestamp).wav"
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ",", with: "-")
            let fileURL = recordingsDir.appendingPathComponent(filename)
            
            _ = try saveFloatArrayToWavFile(samples: chunk.floats, fileURL: fileURL)
            print("Saved audio file: \(fileURL.path)")
            
            // Process each chunk separately for speech recognition
            if hasSpeechRecognitionPermission {
                // Clear previous transcription
                transcription = "Transcribing..."
                
                // Process each audio chunk with a new recognition request
                try await processChunkAsSeparateTranscription(chunk.floats)
            }
        }
        
        isRecording = false
    }
    
    private func processChunkAsSeparateTranscription(_ samples: [Float]) async throws {
        // Cancel any previous recognition task
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        
        // Create a new recognition request for this chunk
        let request = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = request
        
        // Convert float array to audio buffer for speech recognition
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        
        // Copy samples to the buffer
        for (index, sample) in samples.enumerated() {
            pcmBuffer.floatChannelData?[0][index] = sample
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        
        // Add the buffer to this request
        request.append(pcmBuffer)
        request.endAudio()  // Signal that we've finished adding audio to this request
        
        return try await withCheckedThrowingContinuation { continuation in
            // Create a local flag to track if we've already resumed
            var hasResumed = false
            
            self.recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: NSError(domain: "SpeechRecognitionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Self was deallocated"]))
                    }
                    return
                }
                
                // Handle errors
                if let error = error {
                    if (error as NSError).code != 216 && !hasResumed { // Skip Cancellation errors
                        self.transcription = "Error: \(error.localizedDescription)"
                        hasResumed = true
                        continuation.resume(throwing: error)
                    } else if !hasResumed {
                        hasResumed = true
                        continuation.resume()
                    }
                    return
                }
                
                // Only update and resume if this is the final result and we haven't resumed yet
                if let result = result, result.isFinal && !hasResumed {
                    self.transcription = result.bestTranscription.formattedString
                    hasResumed = true
                    continuation.resume()
                    return
                }
                
                // If we have a result but it's not final, just update the text without resuming
                if let result = result, !result.isFinal {
                    self.transcription = "Processing: " + result.bestTranscription.formattedString
                }
            }
            
            // Set a timeout to ensure we don't hang indefinitely
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds timeout
                if !hasResumed {
                    hasResumed = true
                    self.transcription = "Transcription timed out. The audio may be too quiet or unclear."
                    continuation.resume()
                }
            }
        }
    }
    
    func stopRecording() {
        audioProcessor.stopRecording()
        
        // End recognition
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
            
            // Keep the existing VAD recorder view
            MyVADRecorderView()
        }
        .padding()
    }
}

#Preview {
    StreamVADView()
}
