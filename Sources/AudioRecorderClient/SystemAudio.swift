//
// https://github.com/atacan
// 24.04.25
	


import Cocoa // Or import AppKit if not using Cocoa umbrella
import CoreAudio
import os.log // For cleaner logging

public enum AudioError: Error {
    case propertyNotFound
    case propertyNotSettable
    case osStatusError(OSStatus)
    case noDefaultDevice
}

public struct SystemAudio {

    public static func isMuted() throws -> Bool {
        // 1. Get the default output device ID
        var defaultOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain // Master element is 0
        )

        let statusDevice = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), // System object
            &defaultOutputDeviceAddress,
            0,                                       // No qualifier data
            nil,                                     // No qualifier data
            &propertySize,
            &defaultOutputDeviceID
        )

        guard statusDevice == noErr else {
            os_log("Error getting default output device: %{public}d", log: .default, type: .error, statusDevice)
            throw AudioError.osStatusError(statusDevice)
        }

        guard defaultOutputDeviceID != kAudioObjectUnknown else {
             os_log("Could not find default output device.", log: .default, type: .error)
             throw AudioError.noDefaultDevice
        }

        // 2. Get the mute state of the default output device
        var isMuted: UInt32 = 0 // 0 = not muted, 1 = muted
        propertySize = UInt32(MemoryLayout<UInt32>.size)

        var mutePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput, // Check the output scope
            mElement: kAudioObjectPropertyElementMain // Master element (channel 0)
        )

        // Check if the property exists first (optional but good practice)
        guard AudioObjectHasProperty(defaultOutputDeviceID, &mutePropertyAddress) else {
             os_log("Device %{public}d does not support the mute property.", log: .default, type: .error, defaultOutputDeviceID)
             throw AudioError.propertyNotFound
        }

        let statusMute = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &mutePropertyAddress,
            0,           // No qualifier data
            nil,         // No qualifier data
            &propertySize,
            &isMuted
        )

        guard statusMute == noErr else {
            os_log("Error getting mute state for device %{public}d: %{public}d", log: .default, type: .error, defaultOutputDeviceID, statusMute)
            throw AudioError.osStatusError(statusMute)
        }

        // 3. Return the boolean state
        return isMuted == 1
    }
    
    public static func setMuted(_ mute: Bool) throws {
        let defaultOutputDeviceID = try getDefaultOutputDeviceID()

        var newMuteValue: UInt32 = mute ? 1 : 0 // 1 = mute, 0 = unmute
        let propertySize = UInt32(MemoryLayout<UInt32>.size)

        var mutePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if the property exists first
        guard AudioObjectHasProperty(defaultOutputDeviceID, &mutePropertyAddress) else {
             os_log("Device %{public}d does not support the SET mute property.", log: .default, type: .error, defaultOutputDeviceID)
             throw AudioError.propertyNotFound
        }

        // Check if the property can be set
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(defaultOutputDeviceID, &mutePropertyAddress, &isSettable)

        guard settableStatus == noErr else {
             os_log("Error checking if mute property is settable for device %{public}d: %{public}d", log: .default, type: .error, defaultOutputDeviceID, settableStatus)
             throw AudioError.osStatusError(settableStatus)
        }

        guard isSettable.boolValue else {
             os_log("The mute property for device %{public}d is not settable.", log: .default, type: .error, defaultOutputDeviceID)
             throw AudioError.propertyNotSettable
        }


        // Set the property value
        let status = AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &mutePropertyAddress,
            0,           // No qualifier data
            nil,         // No qualifier data
            propertySize,
            &newMuteValue // Pass the address of the value to set
        )

        guard status == noErr else {
            os_log("Error setting mute state for device %{public}d to %{public}d: %{public}d", log: .default, type: .error, defaultOutputDeviceID, newMuteValue, status)
            throw AudioError.osStatusError(status)
        }

        os_log("Successfully set mute state for device %{public}d to: %{public}@", log: .default, type: .info, defaultOutputDeviceID, mute ? "MUTED" : "UNMUTED")
    }

    // --- Helper function to get the default output device ID ---
    private static func getDefaultOutputDeviceID() throws -> AudioDeviceID {
        var defaultOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var defaultOutputDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let statusDevice = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputDeviceAddress,
            0, nil, // No qualifier
            &propertySize,
            &defaultOutputDeviceID
        )

        guard statusDevice == noErr else {
            os_log("Error getting default output device: %{public}d", log: .default, type: .error, statusDevice)
            throw AudioError.osStatusError(statusDevice)
        }

        guard defaultOutputDeviceID != kAudioObjectUnknown else {
             os_log("Could not find default output device.", log: .default, type: .error)
             throw AudioError.noDefaultDevice
        }

        return defaultOutputDeviceID
    }
}

