import Foundation

/// What the media engine reports to the call.
public enum MediaEvent: Sendable, Equatable {
    case connected
    case interrupted
    /// Audio level 0...1 per remote track name (and the local one), a few times a second.
    case levels([String: Float])
}

/// The audio side of a call: WebRTC with Cloudflare Realtime and the FrameCryptor in the app, a fake in tests.
/// The engine encrypts every outgoing frame and decrypts every incoming one with the keys it gets via `frameKeys`;
/// it must drop frames it can't decrypt rather than play them.
public protocol CallMediaEngine: AnyObject, Sendable {
    var frameKeys: FrameKeyInstaller { get }
    var events: AsyncStream<MediaEvent> { get }
    /// Opens a Realtime session through the calls API and publishes the microphone as `trackName`.
    func start(callId: String, iceServers: [IceServer], api: CallsAPI, trackName: String) async throws
    func subscribe(_ tracks: [TrackRef]) async throws
    func unsubscribe(_ tracks: [TrackRef]) async
    func setMuted(_ muted: Bool)
    func setSpeakerOn(_ speakerOn: Bool)
    func stop() async
}
