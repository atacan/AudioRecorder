//
// https://github.com/atacan
// 25.05.25
	


import AVFoundation
import AudioToolbox

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isRecording = false
    
    // MARK: - Device Discovery
    
    /// Get all available audio input devices
    func getAvailableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var devices: [(id: AudioDeviceID, name: String)] = []
        
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
        
        guard status == noErr else { return devices }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &propertyAddress,
                                          0,
                                          nil,
                                          &dataSize,
                                          &deviceIDs)
        
        guard status == noErr else { return devices }
        
        for deviceID in deviceIDs {
            if isInputDevice(deviceID: deviceID) {
                let deviceName = getDeviceName(deviceID: deviceID)
                devices.append((id: deviceID, name: deviceName))
            }
        }
        
        return devices
    }
    
    private func isInputDevice(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID,
                                                   &propertyAddress,
                                                   0,
                                                   nil,
                                                   &dataSize)
        
        guard status == noErr else { return false }
        
        let bufferList = AudioBufferList.allocate(maximumBuffers: Int(dataSize) / MemoryLayout<AudioBuffer>.size)
        defer { free(bufferList.unsafeMutablePointer) }
        
        let getStatus = AudioObjectGetPropertyData(deviceID,
                                                  &propertyAddress,
                                                  0,
                                                  nil,
                                                  &dataSize,
                                                  bufferList.unsafeMutablePointer)
        
        guard getStatus == noErr else { return false }
        
        let buffers = UnsafeBufferPointer(start: bufferList.unsafeMutablePointer.pointee.mBuffers,
                                         count: Int(bufferList.unsafeMutablePointer.pointee.mNumberBuffers))
        
        return buffers.contains { $0.mNumberChannels > 0 }
    }
    
    private func getDeviceName(deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID,
                                                   &propertyAddress,
                                                   0,
                                                   nil,
                                                   &dataSize)
        
        guard status == noErr else { return "Unknown Device" }
        
        var deviceName: CFString?
        status = AudioObjectGetPropertyData(deviceID,
                                          &propertyAddress,
                                          0,
                                          nil,
                                          &dataSize,
                                          &deviceName)
        
        guard status == noErr, let name = deviceName else { return "Unknown Device" }
        
        return name as String
    }
    
    // MARK: - Recording
    
    /// Start recording from a specific microphone
    func startRecording(deviceID: AudioDeviceID, to fileURL: URL) throws {
        guard !isRecording else {
            throw AudioRecorderError.alreadyRecording
        }
        
        // Create audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw AudioRecorderError.engineCreationFailed
        }
        
        // Set the input device
        try setInputDevice(deviceID: deviceID, engine: engine)
        
        // Get input node and format
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Create output file
        audioFile = try AVAudioFile(forWriting: fileURL, settings: inputFormat.settings)
        guard let file = audioFile else {
            throw AudioRecorderError.fileCreationFailed
        }
        
        // Install tap to record audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            do {
                try file.write(from: buffer)
            } catch {
                print("Error writing audio buffer: \(error)")
            }
        }
        
        // Prepare and start engine
        engine.prepare()
        try engine.start()
        
        isRecording = true
    }
    
    private func setInputDevice(deviceID: AudioDeviceID, engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit
        
        var deviceIDVar = deviceID
        let status = AudioUnitSetProperty(audioUnit,
                                        kAudioOutputUnitProperty_CurrentDevice,
                                        kAudioUnitScope_Global,
                                        0,
                                        &deviceIDVar,
                                        UInt32(MemoryLayout<AudioDeviceID>.size))
        
        guard status == noErr else {
            throw AudioRecorderError.deviceSetupFailed(status)
        }
    }
    
    /// Stop recording
    func stopRecording() {
        guard isRecording else { return }
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        isRecording = false
    }
    
    var recording: Bool {
        return isRecording
    }
}

// MARK: - Error Types

enum AudioRecorderError: Error, LocalizedError {
    case alreadyRecording
    case engineCreationFailed
    case deviceSetupFailed(OSStatus)
    case fileCreationFailed
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress"
        case .engineCreationFailed:
            return "Failed to create audio engine"
        case .deviceSetupFailed(let status):
            return "Failed to set audio device (Error: \(status))"
        case .fileCreationFailed:
            return "Failed to create audio file"
        case .permissionDenied:
            return "Microphone permission denied"
        }
    }
}

// MARK: - Usage Example

class AudioRecorderExample {
    private let recorder = AudioRecorder()
    
    func demonstrateUsage() {
        // First, request microphone permission
        requestMicrophonePermission { [weak self] granted in
            guard granted else {
                print("Microphone permission denied")
                return
            }
            
            self?.listAndRecordFromDevice()
        }
    }
    
    private func listAndRecordFromDevice() {
        // Get available input devices
        let devices = recorder.getAvailableInputDevices()
        
        print("Available input devices:")
        for (index, device) in devices.enumerated() {
            print("\(index): \(device.name) (ID: \(device.id))")
        }
        
        // For demo purposes, use the first available device
        guard let firstDevice = devices.first else {
            print("No input devices found")
            return
        }
        
        print("Recording from: \(firstDevice.name)")
        
        // Create output file URL
        let documentsPath = FileManager.default.urls(for: .documentsDirectory,
                                                    in: .userDomainMask).first!
        let outputURL = documentsPath.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        
        do {
            // Start recording
            try recorder.startRecording(deviceID: firstDevice.id, to: outputURL)
            print("Recording started. File will be saved to: \(outputURL.path)")
            
            // Record for 10 seconds (in a real app, you'd probably have UI controls)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.recorder.stopRecording()
                print("Recording stopped")
            }
            
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}