//
// https://github.com/atacan
// 24.04.25
	

import SwiftUI
import AudioRecorderClient

struct IsMutedView: View {
    var body: some View {
        Button {
             checkMuteStatus()
        }
        label: {
            Text("Check muted")
        }
        
        Button {
             muteSpeakers()
        }
        label: {
            Text("Mute speakers")
        }

        Button {
             unmuteSpeakers()
        }
        label: {
            Text("UNmute speakers")
        }
    }
}

func checkMuteStatus() {
    do {
        let muted = try SystemAudio.isMuted()
        if muted {
            print("System Speakers are MUTED")
            // Update your UI accordingly (e.g., show a muted icon)
        } else {
            print("System Speakers are UNMUTED")
            // Update your UI accordingly (e.g., show an unmuted icon)
        }
    } catch let error as AudioError {
        // Handle specific audio errors
        switch error {
        case .propertyNotFound:
            print("Error: The default audio device doesn't have a 'mute' property.")
        case .osStatusError(let status):
            print("Error: Core Audio OSStatus error: \(status)")
        case .noDefaultDevice:
            print("Error: Could not find the default audio output device.")
        case .propertyNotSettable:
            print("Error: propertyNotSettable")
        case .notSupportedOnPlatform:
            print("Error: notSupportedOnPlatform")
        case .couldNotActivateAudioSession:
            print("Error: couldNotActivateAudioSession")
        }
        // Handle the error appropriately in your UI
    } catch {
        // Handle any other unexpected errors
        print("An unexpected error occurred: \(error)")
        // Handle the error appropriately in your UI
    }
}

// Example function to specifically unmute
func unmuteSpeakers() {
    do {
        try SystemAudio.setMuted(false) // Pass false to unmute
        print("Attempted to UNMUTE speakers.")
        // You might want to call isMuted() again here to confirm,
        // though setMuted should throw if it fails.
    } catch let error as AudioError {
        switch error {
        case .propertyNotFound:
            print("Error: Cannot unmute - The default audio device doesn't have a 'mute' property.")
        case .propertyNotSettable:
             print("Error: Cannot unmute - The mute property on the default device cannot be changed programmatically.")
        case .osStatusError(let status):
            print("Error: Cannot unmute - Core Audio OSStatus error: \(status)")
        case .noDefaultDevice:
             print("Error: Cannot unmute - Could not find the default audio output device.")
        case .notSupportedOnPlatform:
            print("Error: Cannot unmute - not supported on platform.")
        case .couldNotActivateAudioSession:
            print("Error: couldNotActivateAudioSession")
        }
    } catch {
        print("An unexpected error occurred while trying to unmute: \(error)")
    }
}

// Example function to specifically mute
func muteSpeakers() {
    do {
        try SystemAudio.setMuted(true) // Pass true to mute
        print("Attempted to MUTE speakers.")
    } catch let error as AudioError {
         // Handle errors similar to unmuteSpeakers()
         print("Error trying to mute: \(error)")
    } catch {
        print("An unexpected error occurred while trying to mute: \(error)")
    }
}


#Preview {
    IsMutedView()
}
