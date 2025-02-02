import AVFoundation
import WhisperKit
import Dependencies
import DependenciesMacros

@DependencyClient
public struct AudioProcessorClient: Sendable {
    public var startRecording: @Sendable () -> AsyncThrowingStream<AudioChunk, Error>
    public var pauseRecording: @Sendable () -> Void
    public var resumeRecording: @Sendable () -> Void
    public var stopRecording: @Sendable () -> Void
    
    public struct AudioChunk {
        public var floats: [Float]
    }
}

extension AudioProcessorClient: DependencyKey {
    public static var liveValue: Self {
        let audioProcessor = AudioProcessor()
        return Self(
            startRecording: { audioProcessor.startRecordingLive() },
            pauseRecording: { audioProcessor.pauseRecording() },
            resumeRecording: { audioProcessor.resumeRecording() },
            stopRecording: { audioProcessor.stopRecording() }
        )
    }
}

import SwiftUI
struct MyVADRecorderView: View {
    var body: some View {
        StreamWithVAD()
    }
}

@MainActor
class StreamWithVADViewModel: ObservableObject {
    private let audioProcessor = AudioProcessor()
    private var isRecording = false
    private var isPaused = false
    private var isSpeechActive = false
    private var currentBuffer: [Float] = []
    private var silenceCounter = 0
    private let silenceThreshold: Float = 0.022  // Adjust this threshold as needed
    private let silenceTimeThreshold = 30  // 3 seconds (30 * 100ms buffers)
    
    @Published var recordingState = "Not Recording"
    
    func toggleRecording() {
        if !isRecording {
            startRecording()
        } else {
            stopRecording()
        }
    }
    
    func togglePause() {
        if isPaused {
            resumeRecording()
        } else {
            pauseRecording()
        }
    }
    
    private func startRecording() {
        do {
            try audioProcessor.startRecordingLive { [weak self] buffer in
                self?.processNewBuffer(buffer)
            }
            isRecording = true
            isPaused = false
            recordingState = "Recording"
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    private func pauseRecording() {
        audioProcessor.pauseRecording()
        isPaused = true
        recordingState = "Paused"
    }
    
    private func resumeRecording() {
        do {
            try audioProcessor.resumeRecordingLive()
            isPaused = false
            recordingState = "Recording"
        } catch {
            print("Failed to resume recording: \(error)")
        }
    }
    
    private func stopRecording() {
        audioProcessor.stopRecording()
        isRecording = false
        isPaused = false
        recordingState = "Not Recording"
        // Save any remaining audio if speech was active
        if isSpeechActive {
            saveCurrentBuffer()
        }
        resetState()
    }
    
    private func processNewBuffer(_ buffer: [Float]) {
        let energy = AudioProcessor.calculateAverageEnergy(of: buffer)
        let isCurrentBufferSilent = energy < silenceThreshold
        
        if !isSpeechActive {
            if !isCurrentBufferSilent {
                // Speech started
                isSpeechActive = true
                silenceCounter = 0
                currentBuffer = buffer
            }
            // If silent, just ignore the buffer
        } else {
            // Speech is active, append the new buffer
            currentBuffer.append(contentsOf: buffer)
            
            if isCurrentBufferSilent {
                silenceCounter += 1
                if silenceCounter >= silenceTimeThreshold {
                    // 3 seconds of silence detected
                    saveCurrentBuffer()
                    resetState()
                    
                    // Clean up memory in AudioProcessor during silence
                    audioProcessor.purgeAudioSamples(keepingLast: 16000) // Keep last 1 second of audio
                }
            } else {
                silenceCounter = 0
            }
        }
    }
    
    private func saveCurrentBuffer() {
        guard !currentBuffer.isEmpty else { return }
        
        // Trim silence from the end
        let trimmedBuffer = trimSilenceFromEnd(currentBuffer)
        
        // Create audio buffer
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimmedBuffer.count))!
        
        // Copy samples to audio buffer
        for (index, sample) in trimmedBuffer.enumerated() {
            audioBuffer.floatChannelData?[0][index] = sample
        }
        audioBuffer.frameLength = AVAudioFrameCount(trimmedBuffer.count)
        
        // Save to file
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        let documentsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(fileName)
        
        do {
            let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            try audioFile.write(from: audioBuffer)
            print("Saved audio file: \(fileURL.path)")
        } catch {
            print("Error saving audio file: \(error)")
        }
    }
    
    private func trimSilenceFromEnd(_ buffer: [Float]) -> [Float] {
        var endIndex = buffer.count - 1
        let chunkSize = 160 // 10ms chunks at 16kHz
        
        // Process in chunks from the end
        while endIndex >= chunkSize {
            let chunk = Array(buffer[(endIndex - chunkSize + 1)...endIndex])
            let energy = AudioProcessor.calculateAverageEnergy(of: chunk)
            
            if energy > silenceThreshold {
                break
            }
            endIndex -= chunkSize
        }
        
        return Array(buffer[0...endIndex])
    }
    
    private func resetState() {
        isSpeechActive = false
        silenceCounter = 0
        currentBuffer = []
    }
}

struct StreamWithVAD: View {
    @StateObject private var viewModel = StreamWithVADViewModel()
    
    var body: some View {
        VStack {
            Text(viewModel.recordingState)
                .padding()
            
            Button(action: {
                viewModel.toggleRecording()
            }) {
                Text(viewModel.recordingState == "Recording" || viewModel.recordingState == "Paused" 
                     ? "Stop Recording" 
                     : "Start Recording")
                    .padding()
                    .background(viewModel.recordingState == "Recording" ? Color.red 
                              : viewModel.recordingState == "Paused" ? Color.orange 
                              : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            if viewModel.recordingState == "Recording" || viewModel.recordingState == "Paused" {
                Button(action: {
                    viewModel.togglePause()
                }) {
                    Text(viewModel.recordingState == "Paused" ? "Resume" : "Pause")
                        .padding()
                        .background(viewModel.recordingState == "Paused" ? Color.green : Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.top, 8)
            }
        }
    }
}
