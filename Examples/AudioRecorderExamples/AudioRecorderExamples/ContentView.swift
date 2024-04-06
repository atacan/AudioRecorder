//
// https://github.com/atacan
// 06.04.24
	

import SwiftUI
import AudioDataStreamClient
import Dependencies

@Observable
class ContentModel {
    var dataCount = 0
    let task: Task<(), any Error>? = nil
    
    
    func start() {
        @Dependency(\.audioDataStream) var audioDataStreamClient
    Task {
            for try await data in await audioDataStreamClient.startTask() {
                dump(data)
                dataCount += data.count
            }
        }
    }
    
    func stop(){
        @Dependency(\.audioDataStream) var audioDataStreamClient

        Task {
            await audioDataStreamClient.stop()
        }
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
