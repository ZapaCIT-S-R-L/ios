import AVFoundation
@preconcurrency import LiveKitWebRTC

/// The audio session during calls. CallKit activates and deactivates it; WebRTC only plays and records while
/// CallKit says so (manual audio). Without this, WebRTC and CallKit fight over the session and a connected call
/// has no voice on either phone.
public enum CallAudio {
    /// Before any audio track exists: WebRTC must not start the session itself.
    public static func leaveSessionToCallKit() {
        #if os(iOS)
            let session = LKRTCAudioSession.sharedInstance()
            session.useManualAudio = true
            session.isAudioEnabled = false
        #endif
    }

    /// When a call starts or is answered, before CallKit activates the session: voice-chat category and mode
    /// (echo cancellation, Bluetooth), as WebRTC expects.
    public static func prepareForCall() {
        #if os(iOS)
            let session = LKRTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            try? session.setConfiguration(LKRTCAudioSessionConfiguration.webRTC())
        #endif
    }

    static var webRTCAudioForTests: (manual: Bool, enabled: Bool) {
        #if os(iOS)
            let session = LKRTCAudioSession.sharedInstance()
            return (session.useManualAudio, session.isAudioEnabled)
        #else
            return (false, false)
        #endif
    }
}
