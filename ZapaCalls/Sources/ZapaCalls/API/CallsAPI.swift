import Foundation

/// The calls service (calls.zapakid.ro, `services/calls` in zapakid-api). All paths are built in `HTTPCallsAPI`,
/// so aligning with `services/calls/openapi.yaml` is a change in one file.
public protocol CallsAPI: Sendable {
    /// Starts a call in a conversation and rings its other members.
    func createCall(conversationId: String) async throws -> CallGrant
    func join(callId: String) async throws -> CallGrant
    func leave(callId: String) async throws
    func decline(callId: String) async throws

    // Cloudflare Realtime, proxied (the app secret stays on the server; only our own session is allowed).
    func newSession(callId: String) async throws -> String
    func addTracks(callId: String, sessionId: String, request: TracksRequest) async throws -> TracksResponse
    func renegotiate(callId: String, sessionId: String, answer: SessionDescription) async throws
    func closeTracks(callId: String, sessionId: String, mids: [String]) async throws -> TracksResponse

    /// The call's event socket (roster, key envelopes, joined/left/ended, ring timeout).
    func openEvents(callId: String) async throws -> CallEventsConnection
}

public protocol CallEventsConnection: Sendable {
    /// The signals from the service; one consumer. Ends when the socket closes.
    func signals() -> AsyncThrowingStream<CallSignal, Error>
    func send(_ signal: OutgoingSignal) async throws
    func close()
}
