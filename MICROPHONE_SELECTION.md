# Microphone Selection Feature

The AudioRecorderClient now supports selecting specific microphones for recording. This is particularly useful on macOS devices that have multiple audio input devices.

## Overview

The microphone selection feature includes:

- `Microphone` struct to represent audio input devices
- Updated `startRecording` method with optional microphone parameter
- `getAvailableMicrophones()` method to discover available microphones
- Automatic fallback to system default when no microphone is specified

## Usage

### 1. Get Available Microphones

```swift
@Dependency(\.audioRecorder) var audioRecorder

let microphones = await audioRecorder.getAvailableMicrophones()
for microphone in microphones {
    print("ID: \(microphone.id), Name: \(microphone.name)")
}
```

### 2. Start Recording with Specific Microphone

```swift
@Dependency(\.audioRecorder) var audioRecorder

// Select a specific microphone
let selectedMicrophone = microphones.first { $0.name.contains("External") }

// Start recording with the selected microphone
let url = URL.documentsDirectory.appendingPathComponent("recording.wav")
let success = try await audioRecorder.startRecording(url, true, selectedMicrophone)
```

### 3. Start Recording with Default Microphone

```swift
@Dependency(\.audioRecorder) var audioRecorder

// Pass nil to use the system default microphone
let url = URL.documentsDirectory.appendingPathComponent("recording.wav")
let success = try await audioRecorder.startRecording(url, true, nil)
```

## Microphone Struct

```swift
public struct Microphone: Sendable, Equatable {
    public let id: String      // Unique identifier for the device
    public let name: String    // Human-readable name
}
```

## Platform Support

- **macOS**: Full support using CoreAudio APIs to enumerate and select input devices
- **iOS**: Limited support - microphone parameter is ignored, uses system default

## Error Handling

The following errors may be thrown when using microphone selection:

```swift
public enum AudioRecorderError: Error, Sendable {
    case invalidMicrophoneID(String)    // Invalid microphone ID provided
    case failedToSetMicrophone(Int)     // Failed to set microphone (CoreAudio error)
}
```

## Example SwiftUI Implementation

```swift
@Observable
class RecordingModel {
    var availableMicrophones: [Microphone] = []
    var selectedMicrophone: Microphone?
    var isRecording = false
    
    init() {
        loadMicrophones()
    }
    
    func loadMicrophones() {
        @Dependency(\.audioRecorder) var audioRecorder
        Task {
            let mics = await audioRecorder.getAvailableMicrophones()
            await MainActor.run {
                self.availableMicrophones = mics
                self.selectedMicrophone = mics.first
            }
        }
    }
    
    func startRecording() {
        @Dependency(\.audioRecorder) var audioRecorder
        Task {
            let url = URL.documentsDirectory.appendingPathComponent("recording.wav")
            do {
                let success = try await audioRecorder.startRecording(url, true, selectedMicrophone)
                await MainActor.run {
                    self.isRecording = success
                }
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
}

struct ContentView: View {
    @State var model = RecordingModel()
    
    var body: some View {
        VStack {
            Picker("Microphone", selection: $model.selectedMicrophone) {
                ForEach(model.availableMicrophones, id: \.id) { microphone in
                    Text(microphone.name).tag(microphone as Microphone?)
                }
            }
            
            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                if model.isRecording {
                    model.stopRecording()
                } else {
                    model.startRecording()
                }
            }
            .disabled(!model.isRecording && model.selectedMicrophone == nil)
        }
    }
}
```

## Backward Compatibility

The changes are backward compatible. Existing code that calls `startRecording(url, playSound)` will continue to work, as the microphone parameter is optional and defaults to `nil` (system default). 