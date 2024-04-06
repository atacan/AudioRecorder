//
// https://github.com/atacan
// 06.04.24


import Foundation
import Dependencies
import AVFoundation

public struct AudioDataStreamClient {
    public var startTask: @Sendable () async -> AsyncThrowingStream<Data, Error>
    public var stop: @Sendable () async -> Void
}

extension AudioDataStreamClient: DependencyKey {
    public static var liveValue: Self {
        let audioActor = AudioActor()
        return Self(
            startTask: {
                await audioActor.startTask()
            },
            stop: {
                await audioActor.dataContinuation?.finish()
            }
        )
    }
}

private actor AudioActor {
    private var audioEngine: AVAudioEngine? = nil
    var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    
    func startTask() async -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.dataContinuation = continuation
            self.audioEngine = AVAudioEngine()
            
            continuation.onTermination = { [audioEngine] _ in
                audioEngine?.stop()
                audioEngine?.inputNode.removeTap(onBus: 0)
            }
            
            self.audioEngine?.inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: self.audioEngine?.inputNode.outputFormat(forBus: 0)
            ) { buffer, when in
                let audioBuffer = buffer.audioBufferList.pointee.mBuffers
                let data = Data(bytes: audioBuffer.mData!, count: Int(audioBuffer.mDataByteSize))
                continuation.yield(data)
            }
            
            self.audioEngine?.prepare()
            do {
                try self.audioEngine?.start()
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }
    }
}

extension DependencyValues {
    public var audioDataStream: AudioDataStreamClient {
        get { self[AudioDataStreamClient.self] }
        set { self[AudioDataStreamClient.self] = newValue }
    }
}
