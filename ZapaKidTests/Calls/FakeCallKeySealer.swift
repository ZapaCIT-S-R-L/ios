import CryptoKit
import Foundation
import ZapaCalls

/// Stands in for the libsignal sealer in tests: AES-GCM with one key per (sender, recipient) device pair, so a blob
/// sealed for one device can't be opened by another, and a tampered blob fails. Not secure: the pair key is derived
/// from the device IDs. The real sealer (libsignal sessions) is wired in by the app.
struct FakeCallKeySealer: CallKeySealer {
    let me: String

    func seal(_ keyMaterial: Data, toDevice: String) async throws -> Data {
        try AES.GCM.seal(keyMaterial, using: Self.pairKey(from: me, to: toDevice)).combined ?? Data()
    }

    func open(_ blob: Data, fromDevice: String) async throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: Self.pairKey(from: fromDevice, to: me))
    }

    static func pairKey(from sender: String, to recipient: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("TEST|\(sender)|\(recipient)".utf8)))
    }
}

/// Records what the call key manager hands to the media engine's frame cryptor.
final class RecordingFrameKeys: FrameKeyInstaller, @unchecked Sendable {
    private let lock = NSLock()
    private var installedKeys: [CallKey] = []
    private var sending: UInt32?

    func install(_ key: CallKey) {
        lock.withLock { installedKeys.append(key) }
    }

    func useForSending(epoch: UInt32) {
        lock.withLock { sending = epoch }
    }

    var installed: [CallKey] {
        lock.withLock { installedKeys }
    }

    var sendingEpoch: UInt32? {
        lock.withLock { sending }
    }
}
