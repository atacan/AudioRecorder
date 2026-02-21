# AudioRecorder Migration Guide (Legacy Clients -> Unified `AudioRecorderClient`)

This guide is for developers migrating from the previous split clients:

- `AudioDataStreamClient`
- `AudioProcessorClient`
- legacy `AudioRecorderClient` API (`currentTime`, `startRecording(url, ...)`, etc.)

The package now exposes a single dependency client: `audioRecorder`.

## What changed

### 1. Package products/targets

Removed:

- `AudioDataStreamClient` product/target
- `AudioProcessorClient` API surface

Kept:

- `AudioRecorderClient` (single product/target)

### 2. Dependency keys

Removed:

- `@Dependency(\.audioDataStream)`
- `@Dependency(\.audioProcessor)`

Use:

- `@Dependency(\.audioRecorder)`

### 3. API shape

Old flat/split APIs are replaced by grouped capabilities:

- `audioRecorder.permissions`
- `audioRecorder.live`
- `audioRecorder.file`

## Quick mapping

| Old | New |
|---|---|
| `audioDataStream.startTask()` | `try await audioRecorder.live.start(.init(mode: .pcm16))` |
| `audioDataStream.stop()` | `try await audioRecorder.live.stop()` |
| `audioProcessor.startRecording(.init())` | `try await audioRecorder.live.start(.init(mode: .vad(.init())))` |
| `audioProcessor.pauseRecording()` | `try await audioRecorder.live.pause()` |
| `audioProcessor.resumeRecording()` | `try await audioRecorder.live.resume()` |
| `audioProcessor.stopRecording()` | `try await audioRecorder.live.stop()` |
| `audioRecorder.requestRecordPermission()` | `audioRecorder.permissions.requestRecordPermission()` |
| `audioRecorder.startRecording(url, onStart)` | `try await audioRecorder.file.start(.init(url: url))` |
| `audioRecorder.currentTime()` | `await audioRecorder.file.currentTime()` |
| `audioRecorder.pauseRecording()` | `try await audioRecorder.file.pause()` |
| `audioRecorder.resumeRecording()` | `try await audioRecorder.file.resume()` |
| `audioRecorder.stopRecording()` | `try await audioRecorder.file.stop()` (returns `FileRecordingResult`) |

## Migration steps

1. Replace imports

```swift
// Remove
import AudioDataStreamClient

// Keep/use
import AudioRecorderClient
```

2. Replace dependency injection keys

```swift
// Remove
@Dependency(\.audioDataStream) var audioDataStream
@Dependency(\.audioProcessor) var audioProcessor

// Use
@Dependency(\.audioRecorder) var audioRecorder
```

3. Migrate per use-case (examples below)

4. Update control flow for file recording:

- Old: `startRecording` could await until recording finished.
- New: `file.start` starts immediately, `file.stop` finalizes and returns metadata.

## Use-case migrations

### A) Raw PCM data streaming (old `audioDataStream`)

```swift
@Dependency(\.audioRecorder) var audioRecorder

let stream = try await audioRecorder.live.start(
  .init(mode: .pcm16, sampleRate: 16_000, channelCount: 1, bufferDuration: 0.1)
)

for try await payload in stream {
  guard case let .pcm16(data) = payload else { continue }
  // send `data` over websocket, etc.
}

try await audioRecorder.live.stop()
```

### B) VAD chunk streaming (old `audioProcessor`)

```swift
@Dependency(\.audioRecorder) var audioRecorder

let vadConfig = VADConfiguration(
  silenceThreshold: 0.022,
  silenceTimeThreshold: 30,
  stopBehavior: .flushBufferedSpeech
)

let stream = try await audioRecorder.live.start(.init(mode: .vad(vadConfig)))

for try await payload in stream {
  guard case let .vadChunk(samples) = payload else { continue }
  // transcribe/process [Float] samples
}

try await audioRecorder.live.stop()
```

### C) File recording (legacy `AudioRecorderClient` methods)

```swift
@Dependency(\.audioRecorder) var audioRecorder

let url = URL(fileURLWithPath: "/tmp/recording.wav")

try await audioRecorder.file.start(.init(url: url))

let now = await audioRecorder.file.currentTime()
print("Current time:", now as Any)

try await audioRecorder.file.pause()
try await audioRecorder.file.resume()

let result = try await audioRecorder.file.stop()
print("Saved:", result.url.path, "duration:", result.duration, "samples:", result.sampleCount)
```

## New core types you will use

- `LiveStreamConfiguration`
- `LiveStreamMode` (`.pcm16`, `.float32`, `.vad(VADConfiguration)`)
- `AudioPayload` (`.pcm16(Data)`, `.float32([Float])`, `.vadChunk([Float])`)
- `VADConfiguration`
- `FileRecordingConfiguration`
- `FileRecordingResult`
- `AudioRecorderClientError`

## Behavioral differences to note

- No backward compatibility layer is provided.
- Live and file recording share one runtime: only one active session at a time.
  - Starting another session while one is active throws `AudioRecorderClientError.sessionAlreadyActive`.
- `pause`/`resume`/`stop` are mode-specific (`live` vs `file`) and throw on invalid usage.
- `SystemAudio` utility remains separate and unchanged.

## Testing migration

`audioRecorder` overrides in tests now use grouped fields:

```swift
withDependencies {
  $0.audioRecorder = AudioRecorderClient(
    permissions: .init(requestRecordPermission: { true }),
    live: .init(
      start: { _ in AsyncThrowingStream { $0.finish() } },
      pause: {},
      resume: {},
      stop: {}
    ),
    file: .init(
      start: { _ in },
      currentTime: { nil },
      pause: {},
      resume: {},
      stop: { .init(url: URL(fileURLWithPath: "/tmp/test.wav"), duration: 0, sampleCount: 0) }
    )
  )
} operation: {
  // test body
}
```

## Troubleshooting

- Compile error: `No such module 'AudioDataStreamClient'`
  - Remove the import and use `import AudioRecorderClient`.
- Compile error: `Value of type 'DependencyValues' has no member 'audioDataStream' / 'audioProcessor'`
  - Replace with `@Dependency(\.audioRecorder)`.
- Pattern mismatch in stream loop
  - `live.start` returns `AudioPayload`; switch/guard on payload case before use.
