//
// https://github.com/atacan
// 24.04.25
	


// Import necessary frameworks for each platform
#if os(macOS)
import Cocoa
import CoreAudio
#else // iOS, tvOS, watchOS
import UIKit
import AVFoundation
import MediaPlayer
#endif

import os.log

public enum AudioError: Error {
    // macOS specific errors
    case propertyNotFound
    case propertyNotSettable
    case noDefaultDevice

    // Generic/cross-platform errors
    case osStatusError(OSStatus)
    case notSupportedOnPlatform
    case couldNotActivateAudioSession
}

public struct SystemAudio {

    // MARK: - Is Muted

    public static func isMuted() throws -> Bool {
        #if os(macOS)
        // --- macOS Implementation (Original Logic) ---
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

        #else // iOS, tvOS, watchOS
        // --- iOS Equivalent Implementation ---
        // On iOS, we check the system's output volume.
        // There is no direct API to check the hardware mute state.

        // It's good practice to ensure the audio session is active.
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.ambient) // Use a category that doesn't interrupt other audio
            try audioSession.setActive(true)
        } catch {
            os_log("Failed to activate audio session: %{public}@", log: .default, type: .error, error.localizedDescription)
            throw AudioError.couldNotActivateAudioSession
        }

        // outputVolume is a value from 0.0 (silent) to 1.0 (full volume).
        let isEffectivelyMuted = audioSession.outputVolume == 0.0

        // Deactivate the session if your app doesn't need it continuously
        // try? audioSession.setActive(false)

        return isEffectivelyMuted
        #endif
    }

    // MARK: - Set Muted

    public static func setMuted(_ mute: Bool) throws {
        #if os(macOS)
        // --- macOS Implementation (Original Logic) ---
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

        #else // iOS, tvOS, watchOS
        // --- iOS Equivalent Implementation ---
        // An app CANNOT programmatically set the system volume or mute state on iOS.
        // This is a system-level restriction. The only way is to guide the user
        // to change the volume themselves, typically by showing an MPVolumeView.
        // Therefore, this function will always fail on iOS.
        os_log("Setting system mute is not supported on iOS.", log: .default, type: .error)
        throw AudioError.notSupportedOnPlatform
        #endif
    }

    // MARK: - macOS Helper
    #if os(macOS)
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
    #endif
}
