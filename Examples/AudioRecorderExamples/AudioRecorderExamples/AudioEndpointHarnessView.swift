import AudioRecorderClient
import Dependencies
import SwiftUI

enum LiveModeOption: String, CaseIterable, Identifiable {
    case pcm16 = "PCM16"
    case float32 = "Float32"
    case vad = "VAD"

    var id: String { rawValue }
}

@MainActor
final class AudioEndpointHarnessModel: ObservableObject {
    @Published var permissionResult = "Not requested"

    @Published var selectedLiveMode: LiveModeOption = .pcm16
    @Published var isLiveRunning = false
    @Published var isLivePaused = false
    @Published var livePayloadCount = 0
    @Published var liveByteCount = 0
    @Published var liveLastSampleCount = 0

    @Published var isFileRecording = false
    @Published var isFilePaused = false
    @Published var fileCurrentTime: TimeInterval?
    @Published var filePath: String
    @Published var fileResultSummary = "No result yet"

    @Published var systemMuteStatus = "Unknown"
    @Published var logs: [String] = []

    private var liveTask: Task<Void, Never>?
    private var fileTimeTask: Task<Void, Never>?

    init() {
        let fileName = "audio-recorder-endpoint-harness-\(Int(Date().timeIntervalSince1970)).wav"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let base = downloads ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appendingPathComponent("AudioRecorderExamples", isDirectory: true)
        self.filePath = directory.appendingPathComponent(fileName).path
    }

    func requestPermissionTapped() async {
        @Dependency(\.audioRecorder) var audioRecorder
        let granted = await audioRecorder.permissions.requestRecordPermission()
        permissionResult = granted ? "Granted" : "Denied"
        appendLog("permissions.requestRecordPermission -> \(granted)")
    }

    func startLiveTapped() async {
        guard !isLiveRunning else { return }
        @Dependency(\.audioRecorder) var audioRecorder

        let mode: LiveStreamMode
        switch selectedLiveMode {
        case .pcm16:
            mode = .pcm16
        case .float32:
            mode = .float32
        case .vad:
            mode = .vad(.init(silenceThreshold: 0.022, silenceTimeThreshold: 30, stopBehavior: .flushBufferedSpeech))
        }

        do {
            let stream = try await audioRecorder.live.start(
                .init(
                    mode: mode,
                    sampleRate: 16_000,
                    channelCount: 1,
                    bufferDuration: 0.1
                )
            )
            isLiveRunning = true
            isLivePaused = false
            livePayloadCount = 0
            liveByteCount = 0
            liveLastSampleCount = 0
            appendLog("live.start mode=\(selectedLiveMode.rawValue)")

            liveTask?.cancel()
            liveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await payload in stream {
                        await self.consumeLivePayload(payload)
                    }
                    await self.appendLog("live stream completed")
                } catch {
                    await self.appendLog("live stream error: \(error)")
                }
                await self.markLiveStopped()
            }
        } catch {
            appendLog("live.start failed: \(error)")
        }
    }

    func pauseLiveTapped() async {
        guard isLiveRunning else { return }
        @Dependency(\.audioRecorder) var audioRecorder
        do {
            try await audioRecorder.live.pause()
            isLivePaused = true
            appendLog("live.pause")
        } catch {
            appendLog("live.pause failed: \(error)")
        }
    }

    func resumeLiveTapped() async {
        guard isLiveRunning else { return }
        @Dependency(\.audioRecorder) var audioRecorder
        do {
            try await audioRecorder.live.resume()
            isLivePaused = false
            appendLog("live.resume")
        } catch {
            appendLog("live.resume failed: \(error)")
        }
    }

    func stopLiveTapped() async {
        @Dependency(\.audioRecorder) var audioRecorder
        do {
            try await audioRecorder.live.stop()
            appendLog("live.stop")
        } catch {
            appendLog("live.stop failed: \(error)")
        }
        markLiveStopped()
    }

    func startFileTapped() async {
        guard !isFileRecording else { return }
        @Dependency(\.audioRecorder) var audioRecorder

        do {
            let fileURL = URL(fileURLWithPath: filePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try await audioRecorder.file.start(
                .init(
                    url: fileURL,
                    sampleRate: 16_000,
                    channelCount: 1
                )
            )
            isFileRecording = true
            isFilePaused = false
            fileCurrentTime = 0
            fileResultSummary = "Recording..."
            appendLog("file.start path=\(filePath)")

            startFileCurrentTimePolling(using: audioRecorder)
        } catch {
            appendLog("file.start failed: \(error)")
        }
    }

    func refreshFileCurrentTimeTapped() async {
        @Dependency(\.audioRecorder) var audioRecorder
        let currentTime = await audioRecorder.file.currentTime()
        fileCurrentTime = currentTime
        appendLog("file.currentTime -> \(currentTime?.formatted(.number.precision(.fractionLength(2))) ?? "nil")")
    }

    func pauseFileTapped() async {
        guard isFileRecording else { return }
        @Dependency(\.audioRecorder) var audioRecorder
        do {
            try await audioRecorder.file.pause()
            isFilePaused = true
            appendLog("file.pause")
        } catch {
            appendLog("file.pause failed: \(error)")
        }
    }

    func resumeFileTapped() async {
        guard isFileRecording else { return }
        @Dependency(\.audioRecorder) var audioRecorder
        do {
            try await audioRecorder.file.resume()
            isFilePaused = false
            appendLog("file.resume")
        } catch {
            appendLog("file.resume failed: \(error)")
        }
    }

    func stopFileTapped() async {
        @Dependency(\.audioRecorder) var audioRecorder
        do {
            let result = try await audioRecorder.file.stop()
            fileResultSummary = "Saved: \(result.url.lastPathComponent), duration: \(result.duration.formatted(.number.precision(.fractionLength(2))))s, samples: \(result.sampleCount)"
            appendLog("file.stop duration=\(result.duration) samples=\(result.sampleCount)")
        } catch {
            appendLog("file.stop failed: \(error)")
            fileResultSummary = "Stop failed: \(error)"
        }

        stopFileCurrentTimePolling()
        isFileRecording = false
        isFilePaused = false
        fileCurrentTime = nil
    }

    func generateNewFilePathTapped() {
        let fileName = "audio-recorder-endpoint-harness-\(Int(Date().timeIntervalSince1970)).wav"
        let base = URL(fileURLWithPath: (filePath as NSString).deletingLastPathComponent, isDirectory: true)
        filePath = base.appendingPathComponent(fileName).path
        appendLog("generated new file path")
    }

    func checkSystemMuteTapped() {
        do {
            let muted = try SystemAudio.isMuted()
            systemMuteStatus = muted ? "Muted" : "Unmuted"
            appendLog("SystemAudio.isMuted -> \(muted)")
        } catch {
            systemMuteStatus = "Error"
            appendLog("SystemAudio.isMuted failed: \(error)")
        }
    }

    func setSystemMutedTapped(_ muted: Bool) {
        do {
            try SystemAudio.setMuted(muted)
            systemMuteStatus = muted ? "Muted" : "Unmuted"
            appendLog("SystemAudio.setMuted(\(muted))")
        } catch {
            appendLog("SystemAudio.setMuted(\(muted)) failed: \(error)")
        }
    }

    private func startFileCurrentTimePolling(using client: AudioRecorderClient) {
        stopFileCurrentTimePolling()
        fileTimeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let currentTime = await client.file.currentTime()
                await self.updateFileCurrentTime(currentTime)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopFileCurrentTimePolling() {
        fileTimeTask?.cancel()
        fileTimeTask = nil
    }

    private func consumeLivePayload(_ payload: AudioPayload) {
        livePayloadCount += 1
        switch payload {
        case let .pcm16(data):
            liveByteCount += data.count
            liveLastSampleCount = data.count / MemoryLayout<Int16>.size
        case let .float32(samples):
            liveByteCount += samples.count * MemoryLayout<Float>.size
            liveLastSampleCount = samples.count
        case let .vadChunk(samples):
            liveByteCount += samples.count * MemoryLayout<Float>.size
            liveLastSampleCount = samples.count
        }
    }

    private func markLiveStopped() {
        liveTask?.cancel()
        liveTask = nil
        isLiveRunning = false
        isLivePaused = false
    }

    private func updateFileCurrentTime(_ value: TimeInterval?) {
        fileCurrentTime = value
    }

    private func appendLog(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        logs.insert("[\(timestamp)] \(message)", at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }
}

struct AudioEndpointHarnessView: View {
    @StateObject private var model = AudioEndpointHarnessModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AudioRecorderClient Endpoint Harness")
                    .font(.title2)
                    .fontWeight(.semibold)

                GroupBox("Permissions Endpoint") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Request Record Permission (`permissions.requestRecordPermission`)") {
                            Task { await model.requestPermissionTapped() }
                        }
                        Text("Result: \(model.permissionResult)")
                            .font(.callout)
                    }
                }

                GroupBox("Live Endpoints") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Live Mode", selection: $model.selectedLiveMode) {
                            ForEach(LiveModeOption.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 10) {
                            Button("Start (`live.start`)") {
                                Task { await model.startLiveTapped() }
                            }
                            .disabled(model.isLiveRunning)

                            Button("Pause (`live.pause`)") {
                                Task { await model.pauseLiveTapped() }
                            }
                            .disabled(!model.isLiveRunning || model.isLivePaused)

                            Button("Resume (`live.resume`)") {
                                Task { await model.resumeLiveTapped() }
                            }
                            .disabled(!model.isLiveRunning || !model.isLivePaused)

                            Button("Stop (`live.stop`)") {
                                Task { await model.stopLiveTapped() }
                            }
                            .disabled(!model.isLiveRunning)
                        }

                        Text("Running: \(model.isLiveRunning ? "Yes" : "No"), Paused: \(model.isLivePaused ? "Yes" : "No")")
                            .font(.callout)
                        Text("Payloads: \(model.livePayloadCount), Last samples: \(model.liveLastSampleCount), Approx bytes: \(model.liveByteCount)")
                            .font(.callout)
                    }
                }

                GroupBox("File Endpoints") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("File Path")
                            .font(.callout.weight(.medium))
                        TextField("Output WAV path", text: $model.filePath)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
                            Button("New Path") {
                                model.generateNewFilePathTapped()
                            }
                            .disabled(model.isFileRecording)

                            Button("Start (`file.start`)") {
                                Task { await model.startFileTapped() }
                            }
                            .disabled(model.isFileRecording)

                            Button("Pause (`file.pause`)") {
                                Task { await model.pauseFileTapped() }
                            }
                            .disabled(!model.isFileRecording || model.isFilePaused)

                            Button("Resume (`file.resume`)") {
                                Task { await model.resumeFileTapped() }
                            }
                            .disabled(!model.isFileRecording || !model.isFilePaused)

                            Button("Stop (`file.stop`)") {
                                Task { await model.stopFileTapped() }
                            }
                            .disabled(!model.isFileRecording)
                        }

                        HStack(spacing: 10) {
                            Button("Refresh Time (`file.currentTime`)") {
                                Task { await model.refreshFileCurrentTimeTapped() }
                            }
                            Text("Current time: \(model.fileCurrentTime?.formatted(.number.precision(.fractionLength(2))) ?? "nil")s")
                                .font(.callout)
                        }

                        Text(model.fileResultSummary)
                            .font(.callout)
                    }
                }

                GroupBox("SystemAudio Utility") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button("Check (`SystemAudio.isMuted`)") {
                                model.checkSystemMuteTapped()
                            }
                            Button("Mute (`SystemAudio.setMuted(true)`)") {
                                model.setSystemMutedTapped(true)
                            }
                            Button("Unmute (`SystemAudio.setMuted(false)`)") {
                                model.setSystemMutedTapped(false)
                            }
                        }
                        Text("System mute status: \(model.systemMuteStatus)")
                            .font(.callout)
                    }
                }

                GroupBox("Event Log") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent endpoint calls and outcomes")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 180, maxHeight: 300)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 900, minHeight: 760)
    }
}

#Preview {
    AudioEndpointHarnessView()
}
