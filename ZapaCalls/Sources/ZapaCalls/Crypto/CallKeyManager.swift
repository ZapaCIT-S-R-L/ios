import Foundation

/// Rotates the call key on every join and leave and hands the new key, sealed per device, to the others.
///
/// The rule every phone follows (iOS and Android alike), so no coordination is needed:
/// - The **leader** is the participant device with the lowest ID (plain string order) in the current roster.
/// - When the roster changes, the leader makes a new random key with epoch = highest epoch seen + 1, uses it at
///   once, and seals it for every other device in the roster. Joiners never get earlier keys; leavers never get
///   later ones.
/// - A phone accepts a key only from the current leader, for its own device, for this call and the epoch in the
///   envelope (one that arrives before its roster update is kept and tried again); it sends with the newest
///   epoch it holds. Older epochs stay in the ring for frames in flight.
public actor CallKeyManager {
    public let callId: String
    public let me: String
    private let sealer: CallKeySealer
    private let frameKeys: FrameKeyInstaller
    private var roster: [String] = []
    private var highestEpoch: UInt32?
    private var sendingEpoch: UInt32?
    /// Envelopes that arrived before the roster update naming their sender as leader (the socket may deliver
    /// them in either order); tried again on the next roster change.
    private var early: [KeyEnvelope] = []

    public init(callId: String, me: String, sealer: CallKeySealer, frameKeys: FrameKeyInstaller) {
        self.callId = callId
        self.me = me
        self.sealer = sealer
        self.frameKeys = frameKeys
    }

    public static func leader(of roster: [String]) -> String? {
        roster.min()
    }

    /// The devices now in the call (including this one). Returns the envelopes to send when this phone leads.
    public func rosterChanged(_ devices: [String]) async throws -> [KeyEnvelope] {
        roster = Array(Set(devices).union([me])).sorted()
        let waiting = early
        early = []
        for envelope in waiting {
            _ = try? await receive(envelope)
        }
        guard Self.leader(of: roster) == me else { return [] }
        let key = CallKey.random(epoch: highestEpoch.map { $0 &+ 1 } ?? 0)
        use(key)
        let material = CallKeyMaterial.encode(key, callId: callId)
        var envelopes: [KeyEnvelope] = []
        for device in roster where device != me {
            let blob = try await sealer.seal(material, toDevice: device)
            envelopes.append(KeyEnvelope(epoch: key.epoch, fromDevice: me, toDevice: device, blob: blob))
        }
        return envelopes
    }

    /// A sealed key relayed by the calls service. Returns false when its sender isn't the leader (yet): the
    /// envelope is kept for the next roster change and used only if that makes its sender the leader.
    @discardableResult
    public func receive(_ envelope: KeyEnvelope) async throws -> Bool {
        guard envelope.toDevice == me else { throw CallKeyError.notForMe }
        guard envelope.fromDevice == Self.leader(of: roster) else {
            early = Array((early + [envelope]).suffix(CallKey.ringSize))
            return false
        }
        let material = try await sealer.open(envelope.blob, fromDevice: envelope.fromDevice)
        let key = try CallKeyMaterial.decode(material, callId: callId, epoch: envelope.epoch)
        use(key)
        return true
    }

    private func use(_ key: CallKey) {
        frameKeys.install(key)
        highestEpoch = max(highestEpoch ?? key.epoch, key.epoch)
        if sendingEpoch.map({ key.epoch > $0 }) ?? true {
            sendingEpoch = key.epoch
            frameKeys.useForSending(epoch: key.epoch)
        }
    }
}
