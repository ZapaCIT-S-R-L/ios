import Foundation

/// The call key per epoch, as the calls service runs it (the same on Android):
/// - The service bumps `epoch` on every join and leave and names the `keyLeader` in the roster.
/// - The leader makes a new random key for that epoch, uses it at once and seals it for every other device; once
///   per epoch. Joiners never get earlier keys; leavers never get later ones.
/// - A phone uses a key only from the current leader, for the current epoch, for this call; one that arrives before
///   its roster is kept and tried when the roster comes. It sends with the newest epoch it holds.
/// Devices are named `<accountId>.<deviceId>` (the sealer's address).
public actor CallKeyManager {
    public let callId: String
    public let me: String
    private let sealer: CallKeySealer
    private let frameKeys: FrameKeyInstaller
    private var roster: [String] = []
    private var epoch: UInt32?
    private var leader: String?
    private var sealedEpochs: Set<UInt32> = []
    private var sendingEpoch: UInt32?
    private var early: [KeyEnvelope] = []

    public init(callId: String, me: String, sealer: CallKeySealer, frameKeys: FrameKeyInstaller) {
        self.callId = callId
        self.me = me
        self.sealer = sealer
        self.frameKeys = frameKeys
    }

    /// The roster from the service. Returns the envelopes to send when this phone leads the epoch.
    public func rosterChanged(_ devices: [String], epoch: UInt32, leader: String?) async throws -> [KeyEnvelope] {
        roster = devices
        self.epoch = epoch
        self.leader = leader
        let waiting = early
        early = []
        for envelope in waiting {
            _ = try? await receive(envelope)
        }
        guard leader == me, !sealedEpochs.contains(epoch) else { return [] }
        sealedEpochs.insert(epoch)
        let key = CallKey.random(epoch: epoch)
        use(key)
        let material = CallKeyMaterial.encode(key, callId: callId)
        var envelopes: [KeyEnvelope] = []
        for device in devices where device != me {
            let blob = try await sealer.seal(material, toDevice: device)
            envelopes.append(KeyEnvelope(epoch: epoch, fromDevice: me, toDevice: device, blob: blob))
        }
        return envelopes
    }

    /// A sealed key relayed by the service. False when it isn't (yet) for the current epoch and leader: one for a
    /// later epoch is kept for the next roster; anything else is dropped.
    @discardableResult
    public func receive(_ envelope: KeyEnvelope) async throws -> Bool {
        guard let epoch, envelope.epoch == epoch, envelope.fromDevice == leader else {
            if envelope.epoch > (epoch ?? 0) {
                early = Array((early + [envelope]).suffix(CallKey.ringSize))
            }
            return false
        }
        let material = try await sealer.open(envelope.blob, fromDevice: envelope.fromDevice)
        try use(CallKeyMaterial.decode(material, callId: callId, epoch: envelope.epoch))
        return true
    }

    private func use(_ key: CallKey) {
        frameKeys.install(key)
        if sendingEpoch.map({ key.epoch > $0 }) ?? true {
            sendingEpoch = key.epoch
            frameKeys.useForSending(epoch: key.epoch)
        }
    }
}
