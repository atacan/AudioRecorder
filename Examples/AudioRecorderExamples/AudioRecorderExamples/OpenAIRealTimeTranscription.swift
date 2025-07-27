//
// https://github.com/atacan
// 21.06.25
	

import SwiftUI
import SwiftOpenAITypes
import OpenAIAsyncHTTPClient
import AudioDataStreamClient
import Dependencies
import Foundation
import Starscream
import WSClient
import HTTPTypes
import Logging

let logger = Logger(label: "Hi")

struct OpenAIRealTimeTranscription: View {
    @State var vc = ViewController()

    var body: some View {
        VStack {
            Button("Start") {
                Task {
                    await withThrowingTaskGroup { group in
                        group.addTask {
//                            @Dependency(\.audioDataStream) var audioStreamClient // This works for Deepgram
//                            for try await data in await audioStreamClient.startTask() {
                            for try await data in startStreamingAudio() { // // This works for OpenAI
                                await vc.socket.write(data: data, completion: nil)
                            }
                        }
//                        group.addTask { // directly to OpenAI
//                        let sessionUpdate = Components.Schemas.RealtimeClientEventTranscriptionSessionUpdate(
//                            _type: .transcription_session_period_update,
//                            session: .init(
//    //                            modalities: [.audio],
//                                input_audio_format: .pcm16,
//                                input_audio_transcription: .init(model: .whisper_hyphen_1),
//                                turn_detection: .init(
//                                    _type: .server_vad,
//    //                                eagerness: .auto,
//                                    threshold: 0.5,
//                                    prefix_padding_ms: 300,
//                                    silence_duration_ms: 500,
//    //                                create_response: true,
//    //                                interrupt_response: true
//                                ),
//                                input_audio_noise_reduction: .init(_type: .near_field),
//                                include: ["item.input_audio_transcription.logprobs"],
//                                client_secret: nil
//                            )
//                        )
//
//                        let sessionUpdateData = try JSONEncoder().encode(sessionUpdate)
//                        let sessionUpdateDataString = String(data: sessionUpdateData, encoding: .utf8)!
//
//    //                    vc.socket.write(data: sessionUpdateData, completion: nil)
//                        vc.socket.write(string: sessionUpdateDataString, completion: nil)
//                            for try await data in startStreamingAudio() {
//                                let audioAppend = Components.Schemas.RealtimeClientEventInputAudioBufferAppend(_type: .input_audio_buffer_period_append, audio: .init(data))
//                                let audioAppendData = try JSONEncoder().encode(audioAppend)
////                                await vc.socket.write(data: audioAppendData, completion: nil) // does not work
//                                let audioAppendDataString = String(data: audioAppendData, encoding: .utf8)!
//                                await vc.socket.write(string: audioAppendDataString, completion: nil)
//                                print(".", terminator: "")
//                            }
//                        }
                    }
                }
            }
        }
    }
}

struct AnotherRealTimeTranscription: View {
    // 1. Create an instance of the streamer
    let audioStreamer = AudioStreamer()
    @State var vc = ViewController()

    var body: some View {
//        Button("WSClient") {
//            let audioDataStream = audioStreamer.startStreaming(
//                targetSampleRate: 16000.0, // <-- Meets 16kHz mandate
//                targetChannels: 1          // <-- Meets Mono mandate
//            )
//            Task {
//                do {
//                    let ws = try await WebSocketClient.connect(
//                        url: "wss://streaming.assemblyai.com/v3/ws",
//                        configuration: WebSocketClientConfiguration(
//                            additionalHeaders: .init(dictionaryLiteral: (HTTPField.Name.authorization, ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"]!))
//                        ),
//
//                        logger: logger
//                    ) { inbound, outbound, context in
//                        Task {
//                            try await outbound.write(.text("Hello"))
//                            for try await audioData in audioDataStream {
//                                // This 'audioData' is now perfectly formatted
//                                // as 16-bit PCM @ 16kHz Mono.
//                                try await outbound.write(.binary(.init(data: audioData)))
//                            }
//                        }
//                        Task {
//                            // you can convert the inbound stream of frames into a stream of full messages using `messages(maxSize:)`
//                            for try await frame in inbound.messages(maxSize: 1 << 14) {
//                                context.logger.info("\(frame.description)")
//                            }
//                        }
//                    }
//                } catch {
//                    print("\(error)")
//                }
//            }
//        }

        Button("Start Real") {

            // 2. Start the stream by calling the function with the mandated format
            let audioDataStream = audioStreamer.startStreaming(
                targetSampleRate: 16000.0, // <-- Meets 16kHz mandate
                targetChannels: 1          // <-- Meets Mono mandate
            )

            // 3. Connect to your server's websocket and send the data
            Task {
                do {
                    // Assume 'yourWebSocket' is an already connected websocket object
                    for try await audioData in audioDataStream {
                        // This 'audioData' is now perfectly formatted
                        // as 16-bit PCM @ 16kHz Mono.
                        vc.socket.write(data: audioData)
                    }
                } catch {
                    print("An error occurred in the audio stream: \(error)")
                }
            }

            // To stop...
            // audioStreamer.stopStreaming()
        }
    }
}

#Preview {
    OpenAIRealTimeTranscription()
}

@Observable
class ViewController: WebSocketDelegate {
    var socket: WebSocket!
    var isConnected = false
    let server = WebSocketServer()

    init() {
//        var request = URLRequest(url: URL(string: "https://echo.websocket.org")!)
//        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
//        var request = URLRequest(url: URL(string: "wss://streaming.assemblyai.com/v3/ws")!)
//        request.addValue("Bearer \(ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)", forHTTPHeaderField: "Authorization")

//        var request = URLRequest(url: URL(string: "ws://127.0.0.1:8080?model=openai.whisper-1")!)
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:8080/transcribe?model=deepgram.nova-2")!)
//          var request = URLRequest(url: URL(string: "ws://127.0.0.1:8080?model=assemblyai.best")!)
//          var request = URLRequest(url: URL(string: "ws://127.0.0.1:8080?model=gladia.standard")!)

        //        var request = URLRequest(url: URL(string: "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=16000&channels=1&model=nova-2&smart_format=true&filler_words=true")!)
//        request.addValue("Token \(ProcessInfo.processInfo.environment["DEEPGRAM_API_TOKEN"]!)", forHTTPHeaderField: "Authorization")
        request.addValue("Bearer [REDACTED]", forHTTPHeaderField: "Authorization")
//        request.addValue(ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"]!, forHTTPHeaderField: "Authorization")
//        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = 59
        socket = WebSocket(request: request)
        socket.delegate = self
        socket.connect()
    }

    // MARK: - WebSocketDelegate
    func didReceive(event: Starscream.WebSocketEvent, client: Starscream.WebSocketClient) {
        switch event {
        case .connected(let headers):
            isConnected = true
            print("websocket is connected: \(headers)")
        case .disconnected(let reason, let code):
            isConnected = false
            print("websocket is disconnected: \(reason) with code: \(code)")
        case .text(let string):
            print("Received text: \(string)")
        case .binary(let data):
            print("Received data: \(data.count)")
        case .ping(_):
            break
        case .pong(_):
            break
        case .viabilityChanged(_):
            break
        case .reconnectSuggested(_):
            break
        case .cancelled:
            isConnected = false
        case .error(let error):
            isConnected = false
            handleError(error)
        case .peerClosed:
            break
        }
    }

    func handleError(_ error: Error?) {
        if let e = error as? WSError {
            print("websocket encountered an error: \(e.message)")
        } else if let e = error {
            print("websocket encountered an error: \(e.localizedDescription)")
        } else {
            print("websocket encountered an error")
        }
    }

    // MARK: Write Text Action

    func writeText() {
        socket.write(string: "hello there!")
    }

    // MARK: Disconnect Action

    func disconnect() {
        if isConnected {
            socket.disconnect()
        } else {
            socket.connect()
        }
    }

}

enum YourCustomError: Error {
    case invalidFormat
    case converterInitializationFailed
}

import AVFoundation

func startStreamingAudio() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        // We will hold a reference to the converter to use in the tap block.
        var audioConverter: AVAudioConverter?

        // Define the target format for the API.
        // Most speech APIs prefer 16kHz mono audio. Double-check your API's documentation.
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16000, // Common for STT
                                               channels: 1,       // Mono is typical for STT
                                               interleaved: true) else {
            continuation.finish(throwing: YourCustomError.invalidFormat)
            return
        }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0) // The microphone's native format

        // Create the converter.
        audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        if audioConverter == nil {
            // This can happen if the conversion is not supported.
            continuation.finish(throwing: YourCustomError.converterInitializationFailed)
            return
        }

        // Install a tap on the input node to get the raw microphone audio.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { buffer, time in
            guard let converter = audioConverter else { return }

            // Create a buffer to hold the converted audio.
            // We need to calculate the correct capacity for the output buffer.
            let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (targetFormat.sampleRate / sourceFormat.sampleRate))
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                return
            }

            var error: NSError?

            // This block provides the original audio buffer to the converter.
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            // Perform the conversion.
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            // Handle conversion errors.
            if status == .error || error != nil {
                print("Audio conversion error: \(error?.localizedDescription ?? "Unknown error")")
                return
            }

            // If conversion is successful, get the resulting data.
            if status == .haveData {
                let data = Data(bytes: outputBuffer.int16ChannelData!.pointee, count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size)
                continuation.yield(data)
            }
        }

        continuation.onTermination = { _ in
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            continuation.finish(throwing: error)
            return
        }
    }
}

import Foundation
import AVFoundation

// Define some simple errors for clarity
enum AudioStreamerError: Error {
    case invalidTargetFormat
    case converterInitializationFailed
    case bufferCreationFailed
}

/// A class that captures audio from the microphone, converts it to a specified format,
/// and streams it as `Data` objects.
class AudioStreamer {

    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    /// Creates an asynchronous stream of audio data, converted to a specified target format.
    ///
    /// - Parameters:
    ///   - targetSampleRate: The desired sample rate for the output audio (e.g., 16000.0 for STT APIs).
    ///   - targetChannels: The desired number of channels (e.g., 1 for mono).
    /// - Returns: An `AsyncThrowingStream` that yields `Data` objects in the target audio format.
    func startStreaming(targetSampleRate: Double, targetChannels: AVAudioChannelCount) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.dataContinuation = continuation

            let inputNode = self.audioEngine.inputNode
            let sourceFormat = inputNode.outputFormat(forBus: 0)

            // Define the target format based on the function parameters.
            // The commonFormat is always .pcmFormatInt16 to meet the "16-bit PCM" part of the mandate.
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: targetSampleRate,
                                                   channels: targetChannels,
                                                   interleaved: true) else {
                continuation.finish(throwing: AudioStreamerError.invalidTargetFormat)
                return
            }

            // Initialize the AVAudioConverter
            self.audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            if self.audioConverter == nil {
                continuation.finish(throwing: AudioStreamerError.converterInitializationFailed)
                return
            }

            // Install a tap on the input node to capture microphone audio.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: sourceFormat) { [weak self] buffer, time in
                guard let self = self, let converter = self.audioConverter else { return }

                // Calculate the required capacity for the output buffer.
                let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (targetFormat.sampleRate / sourceFormat.sampleRate))
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                    print("Error: Failed to create output buffer")
                    return
                }

                var error: NSError? = nil

                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                // Perform the conversion
                let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

                if let error = error {
                    print("Audio conversion error: \(error.localizedDescription)")
                    return
                }

                // If conversion is successful, get the data and yield it to the stream.
                if status == .haveData {
                    let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
                    if let mData = audioBuffer.mData {
                        let data = Data(bytes: mData, count: Int(audioBuffer.mDataByteSize))
                        self.dataContinuation?.yield(data)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
            }

            self.audioEngine.prepare()

            do {
                try self.audioEngine.start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Stops the audio engine and terminates the stream.
    func stopStreaming() {
        self.dataContinuation?.finish()
        self.audioEngine.stop()
    }
}
