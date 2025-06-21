import AVFoundation
import CoreAudio // For AudioDeviceID and related properties
import Cocoa     // For a simple command-line app or testing

// Helper to get AudioDeviceID from AVCaptureDevice.uniqueID
func getAudioDeviceID(fromCaptureDeviceUniqueID uniqueID: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress( // << CHANGED TO VAR
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster // Use Master, Main is deprecated synonym
    )
    
    var propertySize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize)
    if status != noErr {
        print("Error getting size for audio devices: \(status)")
        return nil
    }
    
    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs)
    if status != noErr {
        print("Error getting audio devices: \(status)")
        return nil
    }
    
    for deviceID in deviceIDs {
        var streamAddress = AudioObjectPropertyAddress( // << CHANGED TO VAR
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMaster
        )
        var streamPropertySize: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamPropertySize)
        if status != noErr || streamPropertySize == 0 {
            continue
        }
        
        var uidAddress = AudioObjectPropertyAddress( // << CHANGED TO VAR
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        var deviceUIDCFString: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &deviceUIDCFString)
        if status == noErr, let uid = deviceUIDCFString as String?, uid == uniqueID {
            return deviceID
        }
    }
    
    print("AudioDeviceID not found for uniqueID: \(uniqueID)")
    return nil
}


class SpecificMicrophoneEngineRecorder {
    
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    private var audioFile: AVAudioFile?
    
    private var availableMicrophones: [AVCaptureDevice] = []
    private var selectedMicrophone: AVCaptureDevice?
    private(set) var selectedAudioDeviceID: AudioDeviceID?
    
    private(set) var isRecording: Bool = false
    private let recordingQueue = DispatchQueue(label: "com.example.audiorecordingqueue", qos: .userInitiated)
    
    init() {
        loadAvailableMicrophones()
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode // This is an AVAudioInputNode
    }
    
    // MARK: - Microphone Management
    
    private func loadAvailableMicrophones() {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown],
                                                                mediaType: .audio,
                                                                position: .unspecified)
        availableMicrophones = discoverySession.devices.filter { $0.hasMediaType(.audio) }
        
        if availableMicrophones.isEmpty {
            print("No microphones found.")
        } else {
            print("Available microphones (AVCaptureDevice):")
            for (index, mic) in availableMicrophones.enumerated() {
                print("\(index): \(mic.localizedName) (UID: \(mic.uniqueID))")
            }
        }
    }
    
    func getAvailableMicrophones() -> [AVCaptureDevice] {
        return availableMicrophones
    }
    
    func getFormattedMicName(device: AVCaptureDevice) -> String {
        return "\(device.localizedName) (Model: \(device.modelID), UID: \(device.uniqueID))"
    }
    
    func selectMicrophone(at index: Int) -> Bool {
        guard index >= 0 && index < availableMicrophones.count else {
            print("Error: Invalid microphone index.")
            selectedMicrophone = nil
            selectedAudioDeviceID = nil
            return false
        }
        let mic = availableMicrophones[index]
        return setInputDevice(for: mic)
    }
    
    func selectMicrophone(byUniqueID uid: String) -> Bool {
        if let mic = availableMicrophones.first(where: { $0.uniqueID == uid }) {
            return setInputDevice(for: mic)
        } else {
            print("Error: Microphone with AVCaptureDevice UID '\(uid)' not found.")
            selectedMicrophone = nil
            selectedAudioDeviceID = nil
            return false
        }
    }
    
    private func setInputDevice(for captureDevice: AVCaptureDevice) -> Bool {
        guard let audioDeviceID = getAudioDeviceID(fromCaptureDeviceUniqueID: captureDevice.uniqueID) else {
            print("Error: Could not retrieve AudioDeviceID for \(captureDevice.localizedName) (UID: \(captureDevice.uniqueID)).")
            selectedMicrophone = nil
            selectedAudioDeviceID = nil
            return false
        }
        
        // ** IMPORTANT: `setDeviceID` requires macOS 10.13+ **
        // Ensure your project's deployment target is set accordingly.
        if #available(macOS 10.13, *) {
            do {
                try inputNode.auAudioUnit.setDeviceID(audioDeviceID) // This is the key call
                selectedMicrophone = captureDevice
                selectedAudioDeviceID = audioDeviceID
                print("AVAudioEngine input node successfully set to: \(captureDevice.localizedName) (AudioDeviceID: \(audioDeviceID))")
                return true
            } catch {
                print("Error setting input device ID (\(audioDeviceID)) for AVAudioEngine's input node: \(error.localizedDescription)")
                // Attempt to fall back to default if setting specific device fails
                do {
                    try inputNode.auAudioUnit.setDeviceID(kAudioObjectUnknown) // kAudioObjectUnknown usually means default
                    print("Fell back to default input device for AVAudioEngine after error.")
                } catch let fallbackError {
                    print("Error falling back to default input device: \(fallbackError.localizedDescription)")
                }
                selectedMicrophone = nil // Clear selection as it failed
                selectedAudioDeviceID = nil
                return false
            }
        } else {
            print("Error: `AVAudioInputNode.setDeviceID` is unavailable on macOS versions older than 10.13. Cannot select specific microphone.")
            print("Please update your project's deployment target to macOS 10.13 or newer.")
            selectedMicrophone = nil
            selectedAudioDeviceID = nil
            return false
        }
    }
    
    // MARK: - Recording Logic
    
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
    
    func startRecording(fileName: String = "engine_recording.caf") {
        guard !isRecording else {
            print("Already recording.")
            return
        }
        guard let selectedMic = selectedMicrophone, selectedAudioDeviceID != nil else {
            print("Error: No microphone selected, its AudioDeviceID could not be determined, or setDeviceID is unavailable on this macOS version.")
            return
        }
        
        requestMicrophonePermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.recordingQueue.async {
                    self.proceedWithRecording(fileName: fileName, selectedMic: selectedMic)
                }
            } else {
                print("Error: Microphone permission denied.")
            }
        }
    }
    
    // ... (rest of the class and helper functions remain the same) ...
    
    private func proceedWithRecording(fileName: String, selectedMic: AVCaptureDevice) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFileURL = documentsPath.appendingPathComponent(fileName)
        print("Recording to: \(audioFileURL.path)")
        
        if FileManager.default.fileExists(atPath: audioFileURL.path) {
            do {
                try FileManager.default.removeItem(at: audioFileURL)
            } catch {
                print("Could not remove existing file: \(error). Recording may fail or append.")
            }
        }
        
        // 1. Prepare the engine FIRST. This allows it to configure based on the selected device.
        //    It's crucial to do this before querying formats for taps.
        do {
            audioEngine.prepare()
        } catch {
            print("Error preparing audio engine: \(error.localizedDescription)")
            // If prepare fails, we can't proceed.
            isRecording = false // Ensure state is correct
            // No tap installed yet, no file open yet.
            // We might want to reset the engine if prepare fails significantly.
            // audioEngine.reset() // Consider if this is appropriate here.
            return
        }
        
        // 2. NOW get the tap format from the input node.
        //    This should now reflect the actual hardware format after prepare().
        //    We are tapping the *output* of the inputNode.
        let tapFormat = inputNode.outputFormat(forBus: 0)
        
        guard tapFormat.sampleRate > 0 && tapFormat.channelCount > 0 else {
            print("Error: Selected input device (\(selectedMic.localizedName)) has an invalid audio format (SampleRate: \(tapFormat.sampleRate), Channels: \(tapFormat.channelCount)) after engine prepare. Cannot record.")
            // Log CoreAudio ASBD for debugging if needed
            if let deviceID = self.selectedAudioDeviceID {
                var asbd = AudioStreamBasicDescription()
                var asbdSize = UInt32(MemoryLayout.size(ofValue: asbd))
                var formatAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamFormat,
                    mScope: kAudioObjectPropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMaster
                )
                let status = AudioObjectGetPropertyData(deviceID, &formatAddress, 0, nil, &asbdSize, &asbd)
                if status == noErr {
                    print("CoreAudio ASBD for \(selectedMic.localizedName) (ID: \(deviceID)): SampleRate=\(asbd.mSampleRate), FormatID=\(asbd.mFormatID.fourCharString), ChannelsPerFrame=\(asbd.mChannelsPerFrame)")
                } else {
                    print("Could not get CoreAudio ASBD for \(selectedMic.localizedName) (ID: \(deviceID)), error: \(status)")
                }
            }
            // If formats are bad, stop the engine if it was started by prepare (though prepare doesn't start it running)
            // and reset.
            audioEngine.stop() // Ensure it's stopped if prepare did more than we thought
            audioEngine.reset()
            isRecording = false
            return
        }
        print("Input node tap format (after prepare): SR=\(tapFormat.sampleRate), CH=\(tapFormat.channelCount), interleaved=\(tapFormat.isInterleaved)")
        
        // 3. Create the file format for writing (e.g., PCM Float32)
        //    Base it on the tapFormat's sample rate and channel count.
        let fileProcessingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: tapFormat.sampleRate,
                                                 channels: tapFormat.channelCount,
                                                 interleaved: tapFormat.isInterleaved) // Match tap for simplicity
        
        guard let validFileProcessingFormat = fileProcessingFormat else {
            print("Error: Could not create a valid AVAudioFormat for the output file.")
            audioEngine.stop()
            audioEngine.reset()
            isRecording = false
            return
        }
        
        do {
            // 4. Initialize the audio file
            audioFile = try AVAudioFile(forWriting: audioFileURL,
                                        settings: validFileProcessingFormat.settings,
                                        commonFormat: validFileProcessingFormat.commonFormat,
                                        interleaved: validFileProcessingFormat.isInterleaved)
            
            // 5. Install the tap
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] (buffer, when) in
                guard let self = self, self.isRecording, let audioFile = self.audioFile else { return }
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    print("Error writing audio buffer to file: \(error.localizedDescription)")
                    // Consider how to handle write errors, e.g., stop recording.
                    // DispatchQueue.main.async { self.stopRecording() }
                }
            }
            
            // 6. Start the engine
            try audioEngine.start()
            isRecording = true
            print("Recording started using \(selectedMic.localizedName). Outputting PCM to \(fileName).")
            
            // ... (inside proceedWithRecording method, in the final catch block) ...
            
        } catch {
            print("Error during audio file setup, tap installation, or starting engine: \(error.localizedDescription)")
            isRecording = false
            
            // Clean up tap: removeTap is safe to call even if no tap is installed.
            // This avoids needing a potentially unreliable check.
            inputNode.removeTap(onBus: 0)
            
            self.audioFile = nil // Ensure file is closed if open
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.reset() // Reset after failure
        }
    }
    // ... (rest of the class) ...        }
    
    // ... (rest of the class, helpers, and example usage) ...
    
    func stopRecording() {
        guard isRecording else {
            return
        }
        
        recordingQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.isRecording = false
            self.inputNode.removeTap(onBus: 0)
            
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
            
            self.audioFile = nil // Closes the file
            self.audioEngine.reset() // Release hardware resources
            
            print("Recording stopped. File should be finalized.")
        }
    }
    
    deinit {
        if isRecording {
            stopRecording()
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
    }
}

// Helper to convert FourCharCode to String
extension FourCharCode {
    var fourCharString: String {
        return String(format: "%c%c%c%c",
                      (self >> 24) & 0xFF,
                      (self >> 16) & 0xFF,
                      (self >> 8) & 0xFF,
                      self & 0xFF)
    }
}


// --- Example Usage (macOS Command Line Tool) ---
func runEngineExample() {
    // ... (rest of the example usage code remains the same) ...
    let recorder = SpecificMicrophoneEngineRecorder()
    
    let mics = recorder.getAvailableMicrophones()
    if mics.isEmpty {
        print("No microphones available to record from.")
        if CFRunLoopGetCurrent() != nil { CFRunLoopStop(CFRunLoopGetCurrent()) } else { exit(0) }
        return
    }
    
    var selected = false
    if let usbMic = mics.first(where: {
        $0.localizedName.lowercased().contains("usb") ||
        ($0.responds(to: Selector(("transportType"))) && $0.value(forKey: "transportType") as? UInt32 == kAudioDeviceTransportTypeUSB)
    }) {
        print("\nAttempting to select USB microphone: \(recorder.getFormattedMicName(device: usbMic))")
        selected = recorder.selectMicrophone(byUniqueID: usbMic.uniqueID)
    }
    
    if !selected, let builtInMic = mics.first(where: { $0.deviceType == .builtInMicrophone }) {
        print("\nUSB microphone not selected or found. Attempting to select built-in microphone: \(recorder.getFormattedMicName(device: builtInMic))")
        selected = recorder.selectMicrophone(byUniqueID: builtInMic.uniqueID)
    }
    
    if !selected && !mics.isEmpty {
        print("\nNeither preferred nor built-in selected. Selecting the first available: \(recorder.getFormattedMicName(device: mics[0]))")
        selected = recorder.selectMicrophone(at: 0)
    }
    
    guard selected else {
        print("Failed to select any microphone for the example. This might be due to macOS version (setDeviceID requires 10.13+) or device issues.")
        if CFRunLoopGetCurrent() != nil { CFRunLoopStop(CFRunLoopGetCurrent()) } else { exit(0) }
        return
    }
    
    if let audioDeviceID = recorder.selectedAudioDeviceID {
        print("Selected AudioDeviceID for recording: \(audioDeviceID)")
    }
    
    print("\nStarting recording for 5 seconds...")
    recorder.startRecording(fileName: "my_specific_mic_recording.caf")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
        print("\nStopping recording...")
        recorder.stopRecording()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            print("Example finished. Check your app's Documents directory for 'my_specific_mic_recording.caf'")
            if CFRunLoopGetCurrent() != nil { CFRunLoopStop(CFRunLoopGetCurrent()) } else { exit(0) }
        }
    }
}

// --- Main execution for command-line tool ---
// Add to your main.swift:

// runEngineExample()
// CFRunLoopRun()

import SwiftUI

struct SpecificMicrophoneEngineRecorderView: View {
    
    var body: some View {
        Button("Record with specific microphone") {
            runEngineExample()
        }
    }
}
