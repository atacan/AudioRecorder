import AVFoundation
import WhisperKit
import Dependencies
import DependenciesMacros

@DependencyClient
public struct AudioProcessorClient: Sendable {
    
    public var startRecording: @Sendable (_ config: VADConfiguration) -> AsyncThrowingStream<AudioChunk, Error> = { _ in .finished() }
    public var pauseRecording: @Sendable () -> Void
    public var resumeRecording: @Sendable () throws -> Void
    public var stopRecording: @Sendable () -> Void
    
    public struct AudioChunk {
        public var floats: [Float]
    }
}

public struct VADConfiguration {
    /// The threshold for silence detection.
    public let silenceThreshold: Float
    /// The number of 100ms buffers to wait before emitting an audio chunk.
    public let silenceTimeThreshold: Int
    
    public init(
        silenceThreshold: Float = 0.022,
        silenceTimeThreshold: Int = 30 // 3 seconds (30 * 100ms buffers)
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceTimeThreshold = silenceTimeThreshold
    }
    
    public init(
        silenceThreshold: Float = 0.022,
        silenceTimeThresholdSeconds: Int
    ) {
        self.silenceThreshold = silenceThreshold
        self.silenceTimeThreshold = silenceTimeThresholdSeconds * 10
    }
}

extension AudioProcessorClient: DependencyKey {
    public static var liveValue: Self {
        let audioProcessor = AudioProcessor()
        
        // Shared state between functions
        class StreamState {
            var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
            var currentBuffer: [Float] = []
            var isSpeechActive = false
            var silenceCounter = 0
            let silenceThreshold: Float
            let silenceTimeThreshold: Int
            let audioProcessor: AudioProcessor
            
            init(audioProcessor: AudioProcessor, config: VADConfiguration) {
                self.audioProcessor = audioProcessor
                self.silenceThreshold = config.silenceThreshold
                self.silenceTimeThreshold = config.silenceTimeThreshold
            }
            
            func setContinuation(_ cont: AsyncThrowingStream<AudioChunk, Error>.Continuation) {
                self.continuation = cont
            }
            
            func resetState() {
                isSpeechActive = false
                silenceCounter = 0
                currentBuffer = []
            }
            
            func processBuffer(_ buffer: [Float]) {
                let energy = AudioProcessor.calculateAverageEnergy(of: buffer)
                let isCurrentBufferSilent = energy < silenceThreshold
                
                if !isSpeechActive {
                    if !isCurrentBufferSilent {
                        // Speech started
                        isSpeechActive = true
                        silenceCounter = 0
                        currentBuffer = buffer
                    }
                    // If silent, just ignore the buffer and clean up memory
                    audioProcessor.purgeAudioSamples(keepingLast: 16000) // Keep last 1 second of audio
                } else {
                    // Speech is active, append the new buffer
                    currentBuffer.append(contentsOf: buffer)
                    
                    if isCurrentBufferSilent {
                        silenceCounter += 1
                        if silenceCounter >= silenceTimeThreshold {
                            // 3 seconds of silence detected, emit the chunk
                            if !currentBuffer.isEmpty {
                                let trimmedBuffer = trimSilenceFromEnd(currentBuffer, silenceThreshold: silenceThreshold)
                                continuation?.yield(.init(floats: trimmedBuffer))
                            }
                            resetState()
                            // Clean up memory during silence
                            audioProcessor.purgeAudioSamples(keepingLast: 16000) // Keep last 1 second of audio
                        }
                    } else {
                        silenceCounter = 0
                    }
                }
            }
        }
        
        return Self(
            startRecording: { config in
                AsyncThrowingStream { continuation in
                    
                    let streamState = StreamState(audioProcessor: audioProcessor, config: config)
                    streamState.setContinuation(continuation)
                    streamState.resetState()
                    
                    do {
                        try audioProcessor.startRecordingLive { buffer in
                            streamState.processBuffer(buffer)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            },
            pauseRecording: {
                audioProcessor.pauseRecording()
            },
            resumeRecording: { 
                try audioProcessor.resumeRecordingLive()
            },
            stopRecording: { 
                audioProcessor.stopRecording()
            }
        )
    }
}

extension DependencyValues {
    public var audioProcessor: AudioProcessorClient {
        get { self[AudioProcessorClient.self] }
        set { self[AudioProcessorClient.self] = newValue }
    }
}

public func saveFloatArrayToWavFile(
    samples: [Float],
    sampleRate: Double = 16000,
    fileName: String? = nil,
    fileURL: URL? = nil
) throws -> URL {
    // Create audio buffer
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    
    // Copy samples to audio buffer
    for (index, sample) in samples.enumerated() {
        audioBuffer.floatChannelData?[0][index] = sample
    }
    audioBuffer.frameLength = AVAudioFrameCount(samples.count)
    
    // Use provided URL or generate one in Downloads directory
    let targetURL: URL
    if let fileURL = fileURL {
        targetURL = fileURL
    } else {
        let actualFileName = fileName ?? "recording_\(Date().timeIntervalSince1970).wav"
        let documentsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let recordingsDir = documentsPath.appendingPathComponent("AudioRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        targetURL = recordingsDir.appendingPathComponent(actualFileName)
    }
    
    // Ensure the directory exists
    try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), 
                                          withIntermediateDirectories: true)
    
    // If file exists, remove it first
    if FileManager.default.fileExists(atPath: targetURL.path) {
        try FileManager.default.removeItem(at: targetURL)
    }
    
    // Save to file
    let audioFile = try AVAudioFile(forWriting: targetURL, settings: format.settings)
    try audioFile.write(from: audioBuffer)
    return targetURL
}

func trimSilenceFromEnd(_ buffer: [Float], silenceThreshold: Float) -> [Float] {
    var endIndex = buffer.count - 1
    let chunkSize = 80 // 5ms chunks at 16kHz for more precise trimming
    let minSilenceToKeep = 8000 // Keep at least 500ms of silence at the end
    let consecutiveNonSilentChunksNeeded = 4 // Keep this the same for stability
    let silenceBufferMultiplier = 24 // Keep 120ms of silence after speech detection
    let maxSilenceToKeep = 12000 // Maximum 750ms of silence to prevent excessive length
    
    var nonSilentChunksCount = 0
    var lastSpeechEndIndex = endIndex // Track the last position where we detected speech
    
    // Process in chunks from the end, but keep at least minSilenceToKeep samples
    while endIndex >= chunkSize && endIndex > minSilenceToKeep {
        let chunk = Array(buffer[(endIndex - chunkSize + 1)...endIndex])
        let energy = AudioProcessor.calculateAverageEnergy(of: chunk)
        
        if energy > silenceThreshold {
            nonSilentChunksCount += 1
            lastSpeechEndIndex = endIndex
            if nonSilentChunksCount >= consecutiveNonSilentChunksNeeded {
                // Found consistent speech, add a larger buffer of silence and return
                let silenceToAdd = chunkSize * silenceBufferMultiplier
                let finalEndIndex = min(lastSpeechEndIndex + silenceToAdd, min(buffer.count - 1, lastSpeechEndIndex + maxSilenceToKeep))
                return Array(buffer[0...finalEndIndex])
            }
        } else {
            // More gradual decrease for robustness
            nonSilentChunksCount = max(0, nonSilentChunksCount - 1) 
        }
        
        endIndex -= chunkSize
    }
    
    // If we get here, either the buffer is too short or it's all silence
    // Keep a significant amount of silence at the end, but not more than the maximum
    let silenceToKeep = min(minSilenceToKeep, maxSilenceToKeep)
    return Array(buffer[0...min(endIndex + silenceToKeep, buffer.count - 1)])
}

import SwiftUI
public struct MyVADRecorderView: View {
    public init (){}
    public var body: some View {
        StreamWithVAD()
    }
}

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
        let trimmedBuffer = trimSilenceFromEnd(currentBuffer, silenceThreshold: self.silenceThreshold)
        
        do {
            let fileURL = try saveFloatArrayToWavFile(samples: trimmedBuffer)
            print("Saved audio file: \(fileURL.path)")
        } catch {
            print("Error saving audio file: \(error)")
        }
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
