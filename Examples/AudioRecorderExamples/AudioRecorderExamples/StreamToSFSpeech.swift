//
// https://github.com/atacan
// 18.03.25
	

import Dependencies
import SwiftUI
import AudioRecorderClient
import Speech

struct StreamToSFSpeech: View {
    var body: some View {
        Button("Record") {
            Task {
                @Dependency(\.audioRecorder) var audioRecorder
                let stream = try await audioRecorder.live.start(.init(mode: .vad(.init())))

                for try await payload in stream {
                    guard case let .vadChunk(samples) = payload else {
                        continue
                    }
                    print("Received chunk with \(samples.count) samples")
                    let text = try await transcribeAudioSamples(samples)
                    print(text)
                }
            }
        }
    }
}

#Preview {
    StreamToSFSpeech()
}



import Speech
import AVFoundation

/// Transcribes an array of audio samples using Apple's Speech Recognition.
/// - Parameters:
///   - samples: Array of float audio samples
///   - sampleRate: Sample rate of the audio (default: 16000 Hz)
///   - locale: Locale for the speech recognizer (default: US English)
/// - Returns: The transcribed text from the audio samples
/// - Throws: Any errors that occur during the transcription process
func transcribeAudioSamples(
    _ samples: [Float],
    sampleRate: Double = 16000,
    locale: Locale = Locale(identifier: "en-US")
) async throws -> String {
    // Create speech recognizer with the specified locale
    guard let speechRecognizer = SFSpeechRecognizer(locale: locale),
          speechRecognizer.isAvailable else {
        throw NSError(
            domain: "TranscriptionError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is unavailable"]
        )
    }
    
    // Create a recognition request
    let request = SFSpeechAudioBufferRecognitionRequest()
    
    // Convert float array to audio buffer for speech recognition
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    
    // Copy samples to the buffer
    for (index, sample) in samples.enumerated() {
        pcmBuffer.floatChannelData?[0][index] = sample
    }
    pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
    
    // Add the buffer to this request and signal end of audio
    request.append(pcmBuffer)
    request.endAudio()
    
    // Perform the recognition
    return try await withCheckedThrowingContinuation { continuation in
        var hasResumed = false
        
        let recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
            // Handle errors
            if let error = error {
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
                return
            }
            
            // Return final result when available
            if let result = result, result.isFinal && !hasResumed {
                hasResumed = true
                continuation.resume(returning: result.bestTranscription.formattedString)
                return
            }
        }
        
        // Set a timeout to ensure we don't hang indefinitely
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds timeout
            if !hasResumed {
                hasResumed = true
                recognitionTask.cancel()
                continuation.resume(returning: "")
            }
        }
    }
}
