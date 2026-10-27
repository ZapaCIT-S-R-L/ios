@preconcurrency import LiveKitWebRTC

/// The FrameCryptor's key ring in shared-key mode: every participant encrypts with the call key of the current
/// epoch and decrypts with whichever epoch a frame names (its key index). The same settings on Android:
/// HKDF, 256-bit AES-GCM, key ring 16, no ratcheting, frames dropped while no key is set.
public final class WebRTCFrameKeys: FrameKeyInstaller, @unchecked Sendable {
    /// HKDF salt for the frame key derivation; must match Android.
    public static let salt = Data("ZapaKid call frame key v1".utf8)

    let provider: LKRTCFrameCryptorKeyProvider
    private let lock = NSLock()
    private var senders: [LKRTCFrameCryptor] = []
    private var sendingIndex: Int32 = 0

    public init() {
        provider = LKRTCFrameCryptorKeyProvider(
            ratchetSalt: Self.salt, ratchetWindowSize: 0, sharedKeyMode: true, uncryptedMagicBytes: nil,
            failureTolerance: -1, keyRingSize: Int32(CallKey.ringSize), discardFrameWhenCryptorNotReady: true,
            keyDerivationAlgorithm: .HKDF, keySize: 256
        )
    }

    public func install(_ key: CallKey) {
        provider.setSharedKey(key.bytes, with: Int32(key.ringIndex))
    }

    public func useForSending(epoch: UInt32) {
        let index = Int32(CallKey.ringIndex(forEpoch: epoch))
        let cryptors = lock.withLock {
            sendingIndex = index
            return senders
        }
        for cryptor in cryptors {
            cryptor.keyIndex = index
        }
    }

    func addSender(_ cryptor: LKRTCFrameCryptor) {
        let index = lock.withLock {
            senders.append(cryptor)
            return sendingIndex
        }
        cryptor.keyIndex = index
    }

    /// The key material at a ring index (tests: what a peer would decrypt with).
    func exported(index: Int) -> Data {
        provider.exportSharedKey(Int32(index))
    }

    var senderIndexes: [Int32] {
        lock.withLock { senders.map(\.keyIndex) }
    }

    func removeAll() {
        lock.withLock { senders.removeAll() }
    }
}
