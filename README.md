# AudioRecorderClient

A Swift package that provides a unified, dependency-injected audio recording client for macOS and iOS. Supports real-time audio streaming, Voice Activity Detection (VAD), and file recording — all through a single testable interface built on [swift-dependencies](https://github.com/pointfreeco/swift-dependencies).

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| macOS    | 13.0           |
| iOS      | 16.0           |

Swift 5.7+, Xcode 15+

## Installation

Add the package via Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/atacan/AudioRecorder", from: "x.y.z"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "AudioRecorderClient", package: "AudioRecorder"),
        ]
    ),
]
```

Or add it in Xcode via **File → Add Package Dependencies**.

## Overview

The client is grouped into three namespaces:

| Namespace     | Purpose |
|---------------|---------|
| `.permissions` | Request microphone access |
| `.live`        | Real-time audio streaming (PCM16, Float32, VAD chunks) |
| `.file`        | Record audio directly to a file |

`SystemAudio` is a separate utility (not part of the client) for reading and setting the system mute state.

Only one session can be active at a time. Starting a second session while one is running throws `.sessionAlreadyActive`.

## Usage

Inject the client via the `@Dependency` macro:

```swift
import AudioRecorderClient
import Dependencies

@Observable
final class RecorderModel {
    @ObservationIgnored
    @Dependency(\.audioRecorder) var audioRecorder
}
```

### Permissions

```swift
let granted = await audioRecorder.permissions.requestRecordPermission()
```

### Live streaming — PCM16

Stream raw 16-bit PCM audio, suitable for sending to speech-to-text APIs:

```swift
let stream = try await audioRecorder.live.start(
    .init(
        mode: .pcm16,
        sampleRate: 16_000,
        channelCount: 1,
        bufferDuration: 0.1
    )
)

for try await payload in stream {
    guard case let .pcm16(data) = payload else { continue }
    // send `data` over a WebSocket, write to disk, etc.
}
```

### Live streaming — Float32

```swift
let stream = try await audioRecorder.live.start(.init(mode: .float32))

for try await payload in stream {
    guard case let .float32(samples) = payload else { continue }
    // process Float array
}
```

### Live streaming — Voice Activity Detection

VAD mode buffers audio and yields a chunk only when speech ends. Silence is automatically trimmed.

```swift
let stream = try await audioRecorder.live.start(
    .init(
        mode: .vad(
            .init(
                silenceThreshold: 0.022,
                silenceTimeThreshold: 30,
                stopBehavior: .flushBufferedSpeech
            )
        )
    )
)

for try await payload in stream {
    guard case let .vadChunk(samples) = payload else { continue }
    print("Speech chunk: \(samples.count) samples")
    // pass to SFSpeechRecognizer, Whisper, Deepgram, etc.
}
```

### Pause / resume / stop

All three live controls are available and throw on invalid state:

```swift
try await audioRecorder.live.pause()
try await audioRecorder.live.resume()
try await audioRecorder.live.stop()
```

### File recording

```swift
let fileURL = URL(fileURLWithPath: "/tmp/recording.wav")

try await audioRecorder.file.start(
    .init(url: fileURL, sampleRate: 16_000, channelCount: 1)
)

// Poll elapsed time while recording
let elapsed: TimeInterval? = await audioRecorder.file.currentTime()

// Pause and resume
try await audioRecorder.file.pause()
try await audioRecorder.file.resume()

// Stop and inspect metadata
let result = try await audioRecorder.file.stop()
print("Saved to \(result.url.lastPathComponent)")
print("Duration: \(result.duration)s, samples: \(result.sampleCount)")
```

### SystemAudio (macOS)

Check and control the system output mute state independently of any recording session:

```swift
import AudioRecorderClient

// Read
let muted = try SystemAudio.isMuted()

// Write (macOS only)
try SystemAudio.setMuted(true)
try SystemAudio.setMuted(false)
```

## Error handling

```swift
public enum AudioRecorderClientError: Error, Sendable {
    case sessionAlreadyActive          // tried to start while another session is running
    case noActiveSession               // called pause/resume/stop with nothing active
    case invalidOperationForActiveMode // e.g. called live.stop() during a file session
    case engineStartFailed
    case converterFailed
    case fileWriteFailed
}
```

`SystemAudio` throws `AudioError`:

```swift
case .noDefaultDevice
case .propertyNotFound
case .propertyNotSettable
case .osStatusError(OSStatus)
case .notSupportedOnPlatform
case .couldNotActivateAudioSession
```

## Testing

The package ships `testValue` and `previewValue` implementations via swift-dependencies.

`testValue` uses `unimplemented` stubs — any endpoint you don't override will fail the test if called. Override only what you need:

```swift
withDependencies {
    $0.audioRecorder.permissions.requestRecordPermission = { true }
    $0.audioRecorder.live.start = { _ in
        AsyncThrowingStream { continuation in
            continuation.yield(.float32([0.1, -0.1, 0.25, -0.25]))
            continuation.finish()
        }
    }
    $0.audioRecorder.live.stop = {}
} operation: {
    // test your model
}
```

Use `previewValue` in SwiftUI previews — it returns a single synthetic payload and finishes immediately.

## Project structure

```
AudioRecorder/
├── Sources/
│   └── AudioRecorderClient/
│       ├── AudioRecorderClient+LiveKey.swift   # AVAudioEngine implementation
│       ├── AudioRecorderClient+TestKey.swift   # testValue / previewValue
│       └── SystemAudio.swift                  # platform mute utilities
├── Tests/
│   └── AudioRecorderClientTests/
├── Examples/
│   └── AudioRecorderExamples/                 # Xcode project with runnable examples
│       ├── AudioEndpointHarnessView.swift     # all endpoints in one UI
│       ├── StreamVADView.swift                # VAD + SFSpeechRecognizer
│       ├── StreamToSFSpeech.swift             # minimal VAD → transcription
│       ├── IsMutedView.swift                  # SystemAudio demo
│       └── OpenAIRealTimeTranscription.swift  # WebSocket streaming example
├── docs/
│   └── MIGRATION_GUIDE.md
└── Package.swift
```

The `Examples/` Xcode project is the best place to see full working patterns. `AudioEndpointHarnessView` exercises every endpoint in one screen with a live event log.

## Building and testing

```bash
# build
swift build

# run tests
swift test
```

No additional tooling is required beyond Xcode and the Swift toolchain.

## Credits

Audio capture and conversion logic is partially adapted from [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT).

## Migration

If you are upgrading from a version that had separate `AudioDataStreamClient` or `AudioProcessorClient` targets, see [docs/MIGRATION_GUIDE.md](docs/MIGRATION_GUIDE.md).
