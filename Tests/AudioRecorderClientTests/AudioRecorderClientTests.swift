import XCTest
import Dependencies
@testable import AudioRecorderClient

let deadbeefID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
let deadbeefURL = URL(fileURLWithPath: "/tmp/DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF.m4a")

@MainActor
final class AudioRecorderClientTests: XCTestCase {
    
    actor TestState {
        var selectedMicrophone: Microphone?
        
        func setMicrophone(_ microphone: Microphone?) {
            selectedMicrophone = microphone
        }
        
        func getMicrophone() -> Microphone? {
            return selectedMicrophone
        }
    }
    
    func testMicrophoneSelection() async throws {
        let testMicrophone = Microphone(id: "test-mic-1", name: "Test Microphone")
        let testState = TestState()
        
        let client = AudioRecorderClient(
            currentTime: { nil },
            requestRecordPermission: { true },
            startRecording: { url, playSound, microphone in
                await testState.setMicrophone(microphone)
                return true
            },
            pauseRecording: { },
            resumeRecording: { },
            stopRecording: { },
            getAvailableMicrophones: {
                return [
                    Microphone(id: "mic-1", name: "Built-in Microphone"),
                    Microphone(id: "mic-2", name: "External Microphone")
                ]
            }
        )
        
        try await withDependencies {
            $0.audioRecorder = client
        } operation: {
            @Dependency(\.audioRecorder) var audioRecorder
            
            // Test getting available microphones
            let microphones = await audioRecorder.getAvailableMicrophones()
            XCTAssertEqual(microphones.count, 2)
            XCTAssertEqual(microphones[0].name, "Built-in Microphone")
            XCTAssertEqual(microphones[1].name, "External Microphone")
            
            // Test recording with specific microphone
            let url = URL(fileURLWithPath: "/tmp/test.wav")
            let success = try await audioRecorder.startRecording(url, false, testMicrophone)
            XCTAssertTrue(success)
            let selectedMic = await testState.getMicrophone()
            XCTAssertEqual(selectedMic?.id, testMicrophone.id)
            XCTAssertEqual(selectedMic?.name, testMicrophone.name)
            
            // Test recording without microphone (should pass nil)
            await testState.setMicrophone(nil)
            let successWithoutMic = try await audioRecorder.startRecording(url, false, nil)
            XCTAssertTrue(successWithoutMic)
            let selectedMicAfter = await testState.getMicrophone()
            XCTAssertNil(selectedMicAfter)
        }
    }
    
    func testMicrophoneEquality() {
        let mic1 = Microphone(id: "1", name: "Microphone 1")
        let mic2 = Microphone(id: "1", name: "Microphone 1")
        let mic3 = Microphone(id: "2", name: "Microphone 2")
        
        XCTAssertEqual(mic1, mic2)
        XCTAssertNotEqual(mic1, mic3)
    }
}
