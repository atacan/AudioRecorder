//
// https://github.com/atacan
// 06.04.24


import SwiftUI
import AudioDataStreamClient
import Dependencies
import AVFoundation
import Deepgram
import DeepgramDependency
import WebSocketDependency

private let apiKey = "Token "

@Observable
class ContentModel {
    var dataCount = 0
    var data = Data()
    let task: Task<(), any Error>? = nil


    func start() {
        @Dependency(\.audioDataStream) var audioDataStreamClient
        @Dependency(\.webSocket) var webSocketClient
        @Dependency(\.continuousClock) var clock

//        Task {
//            for try await data in await audioDataStreamClient.startTask() {
////                try await Task.sleep(nanoseconds: NSEC_PER_SEC)
////                dump(data)
//                dataCount += data.count
//                self.data += data
//                try await webSocketClient.send(id: WebSocketClient.ID(), message: .data(data))
//            }
//        }

        Task {
//            let url = URL(string: "wss://echo.websocket.events")!
            let url = URL(string: "wss://api.deepgram.com/v1/listen?encoding=linear16&sample_rate=48000&channels=1&model=nova&smart_format=true&filler_words=true")!
            var urlRequest = URLRequest(url: url)
            urlRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")

            let actions = await webSocketClient.open(
                id: WebSocketClient.ID(),
                url: urlRequest,
                protocols: []
            )
            await withThrowingTaskGroup(of: Void.self) { group in
                for await action in actions {
                    print("action", action)
                    // NB: Can't call `await send` here outside of `group.addTask` due to task local
                    //     dependency mutation in `Effect.{task,run}`. Can maybe remove that explicit task
                    //     local mutation (and this `addTask`?) in a world with
                    //     `Effect(operation: .run { ... })`?
//                    group.addTask { await send(.webSocket(action)) }
                    switch action {
                    case .didOpen:
                        group.addTask {
                            while !Task.isCancelled {
                                try await clock.sleep(for: .seconds(1))
                                try? await webSocketClient.sendPing(id: WebSocketClient.ID())
                                try await webSocketClient.send(id: WebSocketClient.ID(), message: .string(##"{"type": "KeepAlive"}"##))
                            }
                        }
                        group.addTask {
                            for try await data in await audioDataStreamClient.startTask() {
                //                try await Task.sleep(nanoseconds: NSEC_PER_SEC)
                //                dump(data)
//                                dataCount += data.count
//                                self.data += data
                                try await webSocketClient.send(id: WebSocketClient.ID(), message: .data(data))
                            }
                        }
                        group.addTask {
                            for await result in try await webSocketClient.receive(id: WebSocketClient.ID()) {
//                                await send(.receivedSocketMessage(result))
                                switch result {
                                case .success(let message):
                                    switch message {
                                    case .data(let data):
                                        print("DATA")
                                    case let .string(text):
                                        let decoder = JSONDecoder()
                                        do {
                                            let deepgramResponse = try decoder.decode(DeepgramStreamingResponse.self, from: text.data(using: .utf8)!)
                                            let firstAlternative = deepgramResponse.channel.alternatives[0]
                                            print(firstAlternative.transcript)
                                        } catch {
                                            let deepgramResponse = try decoder.decode(DeepgramFinalizeConfirmation.self, from: text.data(using: .utf8)!)
                                            print(deepgramResponse)
                                        }
                                    }
                                case .failure(let failure):
                                    dump(failure)
                                }
                            }
                        }
                    case let .didClose(code, data):
                        dump(code.rawValue)
//                        dump(data)
//                        dump(String(data: data!, encoding: .utf8))
                        return
                    }
                }
            }
        }
    }

    func stop(){
        @Dependency(\.audioDataStream) var audioDataStreamClient

        @Dependency(\.webSocket) var webSocketClient

        Task {
            await audioDataStreamClient.stop()
            
            try await webSocketClient.send(id: WebSocketClient.ID(), message: .string("""
                {
                  "type": "Finalize"
                }
                """))
//            try await webSocketClient.close(id: WebSocketClient.ID(), code: .normalClosure, reason: nil)
        }

//        do {
//            let player = try AVAudioPlayer(data: self.data, fileTypeHint: AVFileType.wav.rawValue)
//            player.prepareToPlay()
//            player.play()
//        } catch {
//        print(error)
//        }
    }
}

struct ContentView: View {
    @State var model = ContentModel()

    var body: some View {
        Button {
            model.start()
        } label: {
            VStack {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("\(model.dataCount)")
            }
            .padding()
        } // <-Button

        Button {
            model.stop()
        } label: {
            Text("Stop")
        } // <-Button
    }
}

#Preview {
    ContentView()
}
