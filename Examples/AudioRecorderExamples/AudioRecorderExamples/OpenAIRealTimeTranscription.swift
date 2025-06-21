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

struct OpenAIRealTimeTranscription: View {
    @State var vc = ViewController()

    var body: some View {
        VStack {
            Button("Start") {
                Task {
                    let sessionUpdate = Components.Schemas.RealtimeClientEventTranscriptionSessionUpdate(
                        _type: .transcription_session_period_update,
                        session: .init(
//                            modalities: [.audio],
                            input_audio_format: .pcm16,
                            input_audio_transcription: .init(model: .whisper_hyphen_1),
                            turn_detection: .init(
                                _type: .server_vad,
//                                eagerness: .auto,
                                threshold: 0.5,	
                                prefix_padding_ms: 300,
                                silence_duration_ms: 500,
//                                create_response: true,
//                                interrupt_response: true
                            ),
                            input_audio_noise_reduction: .init(_type: .near_field),
                            include: ["item.input_audio_transcription.logprobs"],
                            client_secret: nil
                        )
                    )

                    let sessionUpdateData = try JSONEncoder().encode(sessionUpdate)
                    let sessionUpdateDataString = String(data: sessionUpdateData, encoding: .utf8)!

//                    vc.socket.write(data: sessionUpdateData, completion: nil)
                    vc.socket.write(string: sessionUpdateDataString, completion: nil)

                    await withThrowingTaskGroup { group in
//                        group.addTask {
//                            @Dependency(\.audioDataStream) var audioDataStreamClient
//                            for try await data in await audioDataStreamClient.startTask() {
//                                let audioAppend = Components.Schemas.RealtimeClientEventInputAudioBufferAppend(_type: .input_audio_buffer_period_append, audio: data.base64EncodedString())
//                                let audioAppendData = try JSONEncoder().encode(audioAppend)
//                                let audioAppendDataString = String(data: audioAppendData, encoding: .utf8)!
//                                await vc.socket.write(string: audioAppendDataString, completion: nil)
//                            }
//                        }
                        group.addTask {
                            for try await data in startStreamingAudio() {
                                let audioAppend = Components.Schemas.RealtimeClientEventInputAudioBufferAppend(_type: .input_audio_buffer_period_append, audio: data.base64EncodedString())
                                let audioAppendData = try JSONEncoder().encode(audioAppend)
//                                await vc.socket.write(data: audioAppendData, completion: nil) // does not work
                                let audioAppendDataString = String(data: audioAppendData, encoding: .utf8)!
                                await vc.socket.write(string: audioAppendDataString, completion: nil)
                            }
                        }
                    }
                }
            }
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
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.addValue("Bearer \(ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
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
