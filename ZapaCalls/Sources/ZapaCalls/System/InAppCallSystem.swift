import Foundation

/// The call UI without CallKit: everything happens on the app's own call screen (the simulator, previews, UI
/// tests, and until the VoIP push setup is done).
@MainActor
public final class InAppCallSystem: CallSystem {
    public weak var actions: CallSystemActions?

    public init() {}

    public func reportIncoming(uuid _: UUID, callerName _: String) async throws {}
    public func startOutgoing(uuid _: UUID, name _: String) async throws {}
    public func reportConnected(uuid _: UUID) {}
    public func reportEnded(uuid _: UUID, reason _: CallSystemEndReason) {}

    public func requestAnswer(uuid: UUID) async throws {
        await actions?.answer(uuid)
    }

    public func requestEnd(uuid: UUID) async throws {
        await actions?.end(uuid)
    }
}
