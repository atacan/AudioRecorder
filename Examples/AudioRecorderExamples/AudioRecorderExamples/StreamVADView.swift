//
// https://github.com/atacan
// 02.02.25


import Dependencies
import SwiftUI
import AudioDataStreamClient

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
    
    func startButtonTapped() async throws {
        let stream = audioProcessor.startRecording()
        
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
        }
    }
}
struct StreamVADView: View {
    @State var model = StreamVADModel()
    
    var body: some View {
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
        } // <-Button
        
        MyVADRecorderView()
    }
}

#Preview {
    StreamVADView()
}
