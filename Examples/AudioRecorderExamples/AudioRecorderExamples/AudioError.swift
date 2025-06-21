import AVFoundation
import CoreAudio
import AudioToolbox // For some kAudio constants

// MARK: - Error Handling
enum AudioErrorr: Error {
    case coreAudioErrorr(OSStatus, String)
    case generalError(String)
    case audioUnitNotAvailable
    case couldNotCreateAudioFile
    case couldNotStartEngine(Error)
    case recordingInProgress
    case noRecordingInProgress
}

// MARK: - Audio Device Representation
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String? // Unique ID, good for saving preferences
    let name: String

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Audio Device Manager
class AudioDeviceManager {

    static func getInputDevices() throws -> [AudioDevice] {
        var devices: [AudioDevice] = []

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                                    &propertyAddress,
                                                    0,
                                                    nil,
                                                    &dataSize)
        if status != noErr {
            throw AudioErrorr.coreAudioErrorr(status, "Failed to get size for hardware devices list.")
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &propertyAddress,
                                            0,
                                            nil,
                                            &dataSize,
                                            &deviceIDs)
        if status != noErr {
            throw AudioErrorr.coreAudioErrorr(status, "Failed to get hardware devices list.")
        }

        for deviceID in deviceIDs {
            // Check if it's an input device using the stream configuration method
            if try hasInputChannels(deviceID: deviceID) {
                if let name = try getDeviceName(deviceID: deviceID),
                   let uid = try getDeviceUID(deviceID: deviceID) {
                    devices.append(AudioDevice(id: deviceID, uid: uid, name: name))
                }
            }
        }
        return devices
    }

    private static func getDevicePropertyCFString(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        if status != noErr {
            // It's possible for a device to not have a UID (e.g. aggregate devices might not)
            // kAudioDevicePropertyModelUID and kAudioDevicePropertyDeviceUID are CFStringRef
             if selector == kAudioDevicePropertyDeviceUID || selector == kAudioDevicePropertyModelUID {
                 if status == kAudioHardwareUnknownPropertyError { return nil } // Property simply doesn't exist for this device
             }
            // For other properties, or if dataSize is 0 (and it's not an expected optional like UID)
            if dataSize == 0 && status == noErr { // Property exists but data is empty
                if selector == kAudioDevicePropertyDeviceUID || selector == kAudioDevicePropertyModelUID { return nil }
            }
            // If it's any other error, or dataSize is 0 for a property that should have it.
            if status != noErr {
                 throw AudioErrorr.coreAudioErrorr(status, "Failed to get size for property \(selector) for device \(deviceID)")
            }
        }
        
        if dataSize == 0 { // No data for this property (e.g., UID might be missing)
            return nil
        }

        var cfString: CFString? = nil
        status = AudioObjectGetPropertyData(deviceID,
                                            &propertyAddress,
                                            0,
                                            nil,
                                            &dataSize,
                                            &cfString)
        if status != noErr {
             // Again, allow missing UIDs gracefully
            if selector == kAudioDevicePropertyDeviceUID || selector == kAudioDevicePropertyModelUID {
                if status == kAudioHardwareUnknownPropertyError { return nil }
            }
            throw AudioErrorr.coreAudioErrorr(status, "Failed to get property \(selector) (CFString) for device \(deviceID)")
        }
        return cfString as String?
    }

    private static func getDeviceName(deviceID: AudioDeviceID) throws -> String? {
        return try getDevicePropertyCFString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func getDeviceUID(deviceID: AudioDeviceID) throws -> String? {
        // Note: Not all devices have UIDs (e.g., some aggregate devices might not).
        return try getDevicePropertyCFString(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func hasInputChannels(deviceID: AudioDeviceID) throws -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, // Check input scope
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID,
                                                    &propertyAddress,
                                                    0,
                                                    nil,
                                                    &dataSize)
        
        if status != noErr {
            // If the property doesn't exist for the input scope, it's not an input device.
            // This is common for output-only devices.
            if status == kAudioHardwareUnknownPropertyError || status == kAudioHardwareBadPropertySizeError {
                return false
            }
            throw AudioErrorr.coreAudioErrorr(status, "Failed to get size for stream configuration on input scope for device \(deviceID). Status: \(status)")
        }

        if dataSize == 0 {
            return false // No input stream configuration data
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        status = AudioObjectGetPropertyData(deviceID,
                                            &propertyAddress,
                                            0,
                                            nil,
                                            &dataSize,
                                            bufferList)
        if status != noErr {
            // If getting data fails (e.g. property missing after size check, though unlikely)
             if status == kAudioHardwareUnknownPropertyError || status == kAudioHardwareBadPropertySizeError {
                return false
            }
            throw AudioErrorr.coreAudioErrorr(status, "Failed to get stream configuration data for device \(deviceID). Status: \(status)")
        }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for i in 0..<buffers.count {
            if buffers[i].mNumberChannels > 0 {
                return true // Found at least one input channel
            }
        }
        return false
    }
}


// MARK: - Specific Microphone Recorder
class SpecificMicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var selectedDeviceID: AudioDeviceID?

    var isRecording: Bool {
        return audioFile != nil && engine.isRunning
    }

    func startRecording(to url: URL, deviceID: AudioDeviceID) throws {
        guard !isRecording else {
            throw AudioErrorr.recordingInProgress
        }
        
        self.selectedDeviceID = deviceID
        let inputNode = engine.inputNode

        // --- This is where the Objective-C snippet is adapted ---
        guard let audioUnit = inputNode.audioUnit else {
            print("Error: Could not get audio unit from input node.")
            throw AudioErrorr.audioUnitNotAvailable
        }

        var deviceID_mut = deviceID // Needs to be a var for the pointer
        let status = AudioUnitSetProperty(audioUnit,
                                          kAudioOutputUnitProperty_CurrentDevice, // For input nodes, this sets the *input* device
                                          kAudioUnitScope_Global,
                                          0, // Input element of the Audio Unit
                                          &deviceID_mut,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))

        if status != noErr {
            print("Error setting input device: \(status)")
            // You might want to reset the engine or inputNode if this fails,
            // as it might be in an inconsistent state.
            // For now, we throw, and the caller should handle cleanup or retries.
            throw AudioErrorr.coreAudioErrorr(status, "Failed to set input device on AudioUnit.")
        }
        // --- End of adapted snippet ---
        
        // Reset the engine to ensure it picks up the new device settings correctly.
        // This step is crucial after changing the underlying device of an audio unit.
        engine.reset()
        engine.connect(inputNode, to: engine.mainMixerNode, format: nil) // Reconnect after reset if necessary for other parts, though for tap it's not always needed for the mainMixerNode.
                                                                      // For just tapping input, direct connection to mixer isn't strictly required,
                                                                      // but resetting helps apply device change.

        // After setting the device AND resetting the engine, the input node's format might change.
        // It's good practice to fetch it now.
        // Ensure the engine is prepared before accessing the format, or it might be nil.
        // However, we need the format to install the tap BEFORE preparing the engine usually.
        // The critical part is that the AudioUnit's device is set.
        // The inputNode.outputFormat should reflect this AFTER the property is set.
        
        // Re-fetch input node to ensure it's current after potential engine changes or resets.
        let currentInputNode = engine.inputNode
        let inputFormat = currentInputNode.outputFormat(forBus: 0)
        
        if inputFormat.sampleRate == 0.0 || inputFormat.channelCount == 0 {
            // This can happen if the device doesn't report a valid format or if the engine
            // isn't properly configured after the device change.
            // Attempt to use a common default, but this is risky.
            print("Warning: Input format from node is invalid (SampleRate: \(inputFormat.sampleRate), Channels: \(inputFormat.channelCount)). This might indicate an issue with device selection or engine state.")
            // throw AudioErrorr.generalError("Input node reported an invalid audio format after device selection.")
            // As a fallback, you might try to get the device's nominal sample rate directly,
            // but AVAudioEngine usually handles this.
        }


        // Let's record in PCM float format.
        // Use the input node's hardware sample rate and channel count.
        let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: inputFormat.sampleRate,
                                            channels: inputFormat.channelCount,
                                            interleaved: false)

        guard let format = recordingFormat, format.sampleRate > 0, format.channelCount > 0 else {
             print("Error: Could not create a valid recording format. Input node format was: SR=\(inputFormat.sampleRate), Ch=\(inputFormat.channelCount)")
            throw AudioErrorr.generalError("Could not create a valid AVAudioFormat for recording. Check device capabilities and input node state.")
        }
        
        print("Attempting to record with: Input node format: \(inputFormat), Recording format: \(format)")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            print("Error creating AVAudioFile: \(error)")
            throw AudioErrorr.couldNotCreateAudioFile
        }

        currentInputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, when) in
            guard let self = self, let audioFile = self.audioFile else { return }
            do {
                // It's possible the buffer from the tap doesn't perfectly match the file's desired format
                // if there were discrepancies. AVAudioFile write usually handles minor conversions if possible.
                try audioFile.write(from: buffer)
            } catch {
                print("Error writing to audio file: \(error)")
                // Consider how to propagate this error if it's critical
            }
        }

        engine.prepare()
        do {
            try engine.start()
            print("Recording started to \(url.path) using device ID \(deviceID)")
        } catch {
            print("Error starting AVAudioEngine: \(error)")
            currentInputNode.removeTap(onBus: 0)
            self.audioFile = nil
            self.selectedDeviceID = nil
            engine.reset() // Clean up engine state
            throw AudioErrorr.couldNotStartEngine(error)
        }
    }

    func stopRecording() throws {
        guard isRecording else {
            throw AudioErrorr.noRecordingInProgress
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        audioFile = nil // This closes the file
        selectedDeviceID = nil
        print("Recording stopped.")
        
        engine.reset() // Reset the engine to release resources and prepare for next use
    }
}

// MARK: - Example Usage (e.g., in a command-line tool or AppDelegate)

func main() {
    // 1. List available input devices
    var availableInputDevices: [AudioDevice] = []
    do {
        availableInputDevices = try AudioDeviceManager.getInputDevices()
        if availableInputDevices.isEmpty {
            print("No input audio devices found.")
            return
        }
        print("Available input audio devices:")
        for (index, device) in availableInputDevices.enumerated() {
            print("\(index + 1). \(device.name) (ID: \(device.id), UID: \(device.uid ?? "N/A"))")
        }
    } catch {
        print("Error listing audio devices: \(error)")
        return
    }

    // 2. Let the user choose (or hardcode for testing)
    guard !availableInputDevices.isEmpty else {
        print("No devices to choose from.")
        return
    }
    
    // Example: Prompt user to select a device
    print("\nEnter the number of the microphone to use:")
    var selectedDevice: AudioDevice?
    if let choiceStr = readLine(), let choiceIndex = Int(choiceStr), choiceIndex > 0 && choiceIndex <= availableInputDevices.count {
        selectedDevice = availableInputDevices[choiceIndex - 1]
    } else {
         // Fallback to the first device if input is invalid or no selection for testing
        print("Invalid selection or no input. Attempting to use the first available device.")
        selectedDevice = availableInputDevices.first
    }
    
    guard let deviceToUse = selectedDevice else {
        print("Could not select a device for recording.")
        return
    }
    
    print("\nWill attempt to record using: \(deviceToUse.name) (ID: \(deviceToUse.id))")

    // 3. Prepare recorder and file URL
    let recorder = SpecificMicrophoneRecorder()
    
    // Create a unique filename with a timestamp
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
    let timestamp = dateFormatter.string(from: Date())
    let filename = "specific_mic_recording_\(timestamp).caf" // .caf is a good Core Audio Format
    
    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let audioFilename = documentsDirectory.appendingPathComponent(filename)

    // Clean up previous recording if any (though unique filename reduces need)
    // if FileManager.default.fileExists(atPath: audioFilename.path) {
    //    try? FileManager.default.removeItem(at: audioFilename)
    // }

    // 4. Start recording
    AVAudioApplication.requestRecordPermission { granted in
        guard granted else {
            print("Microphone permission denied.")
            // In a real app, you'd want to inform the user more gracefully.
            // For a command line tool, exiting or preventing further action is typical.
            exit(1) // Or handle appropriately
            return
        }
        
        // Permission granted, proceed with recording
        // Ensure engine operations are on a consistent thread, often main for simplicity unless background is needed.
        // For command-line tool, direct execution is fine here as it's after permission.
        do {
            try recorder.startRecording(to: audioFilename, deviceID: deviceToUse.id)
            print("Recording... Press Enter to stop.")
            
            // Keep the program running for recording
            _ = readLine() // Wait for Enter press to stop

            // Stop recording
            if recorder.isRecording {
                try recorder.stopRecording()
                print("Recording saved to: \(audioFilename.path)")
            } else {
                print("Recorder was not active or already stopped before Enter was pressed.")
            }
            exit(0) // Successful exit

        } catch {
            print("Error during recording process: \(error)")
            // If startRecording failed, try to clean up
            if recorder.isRecording {
                try? recorder.stopRecording() // Attempt to stop if it somehow started
            }
            exit(1) // Error exit
        }
    }
    
    // Keep the run loop active for the permission handler and subsequent recording in a command-line tool
    // This is essential if the main thread would otherwise exit before async operations complete.
    RunLoop.main.run()
}

// Call main (for command-line tool style)
// If in an App, you would integrate this into your App's lifecycle / UI.
// To run this, create a macOS Command Line Tool project in Xcode,
// replace the contents of main.swift with this code,
// and add NSMicrophoneUsageDescription to the Info.plist file.
// main()

// --- SwiftUI Conceptual Wrapper (No changes from previous, shown for completeness) ---

import SwiftUI

struct SpecificMicrophoneRecorderWrapperView: View {
    @StateObject var recorderWrapper = SpecificMicrophoneRecorderWrapper()

    var body: some View {
        VStack {
            if recorderWrapper.availableDevices.isEmpty {
                Text("Loading devices...")
                    .onAppear { recorderWrapper.loadDevices() }
            } else {
                Picker("Select Microphone", selection: $recorderWrapper.selectedDeviceID) {
                    Text("None").tag(Optional<AudioDeviceID>(nil)) // Allow no selection
                    ForEach(recorderWrapper.availableDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .disabled(recorderWrapper.isRecording)
            }

            Button(recorderWrapper.isRecording ? "Stop Recording" : "Start Recording") {
                recorderWrapper.toggleRecording()
            }
            .disabled(recorderWrapper.selectedDeviceID == nil && !recorderWrapper.isRecording)
            // Disable if no mic is selected (and not already recording)

            if let message = recorderWrapper.statusMessage {
                Text(message)
                    .padding(.top)
            }
            
            if recorderWrapper.isRecording {
                 Text("Recording to: \(recorderWrapper.currentRecordingFileName ?? "Default File")")
            }
        }
        .padding()
        .onAppear {
             recorderWrapper.requestPermission()
        }
    }
}

class SpecificMicrophoneRecorderWrapper: ObservableObject {
    @Published var availableDevices: [AudioDevice] = []
    @Published var selectedDeviceID: AudioDeviceID? = nil
    @Published var isRecording: Bool = false
    @Published var statusMessage: String? = nil
    @Published var currentRecordingFileName: String? = nil


    private let recorder = SpecificMicrophoneRecorder()
    private var audioFileURL: URL?

    init() {
        // loadDevices() // Load devices when view appears or explicitly called
        // setupAudioFileURL() // Setup file URL when starting recording
    }
    
    func requestPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted {
                    self?.statusMessage = "Microphone permission denied."
                } else {
                    self?.statusMessage = "Microphone permission granted. You can now select a device and record."
                }
            }
        }
    }

    func loadDevices() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let devices = try AudioDeviceManager.getInputDevices()
                DispatchQueue.main.async {
                    self?.availableDevices = devices
                    if devices.isEmpty {
                        self?.statusMessage = "No input audio devices found."
                    } else {
                        // self?.selectedDeviceID = devices.first?.id // Optionally pre-select
                        self?.statusMessage = "Found \(devices.count) input devices."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusMessage = "Error loading devices: \(error.localizedDescription)"
                    print(error)
                }
            }
        }
    }

    private func setupNewAudioFileURL() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "app_recording_\(timestamp).caf"
        audioFileURL = documentsDirectory.appendingPathComponent(filename)
        currentRecordingFileName = filename
    }

    func toggleRecording() {
        if recorder.isRecording {
            do {
                try recorder.stopRecording()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "Recording stopped. Saved as \(self.currentRecordingFileName ?? "recording.caf")"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Error stopping: \(error.localizedDescription)"
                    print(error)
                }
            }
        } else {
            guard let deviceID = selectedDeviceID else {
                statusMessage = "Please select a microphone."
                return
            }
            
            setupNewAudioFileURL() // Prepare a new file URL for this recording session
            
            guard let fileURL = audioFileURL else {
                 statusMessage = "Could not create audio file URL."
                 return
            }

            // Deleting existing file with the same name (optional, as we use timestamps now)
            // if FileManager.default.fileExists(atPath: fileURL.path) {
            //    try? FileManager.default.removeItem(at: fileURL)
            // }
            
            do {
                try recorder.startRecording(to: fileURL, deviceID: deviceID)
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.statusMessage = "Recording started..."
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRecording = false // Ensure state is consistent on failure
                    self.statusMessage = "Error starting: \(error.localizedDescription)"
                    print(error)
                }
            }
        }
    }
}

