import Foundation

/// Seals the call key for one recipient device and opens what another device sealed for this one. The app
/// implements it with libsignal sessions (the chat key setup); tests use a fake. Implementations must
/// authenticate the sender: `open` fails unless `fromDevice` really sealed the blob for this device.
public protocol CallKeySealer: Sendable {
    func seal(_ keyMaterial: Data, toDevice: String) async throws -> Data
    func open(_ blob: Data, fromDevice: String) async throws -> Data
}

/// Where the keys go: the media engine's frame cryptor (WebRTC's FrameCryptor key provider, shared-key mode).
public protocol FrameKeyInstaller: Sendable {
    /// Makes the key available for decrypting frames tagged with its ring index.
    func install(_ key: CallKey)
    /// Encrypts outgoing frames with this epoch's key from now on.
    func useForSending(epoch: UInt32)
}

/// A sealed key on its way through the calls service, which relays it to `toDevice` and nothing else. Devices are
/// `<accountId>.<deviceId>`; on the wire they become `toAccount`/`toDevice` (out) and `fromAccount`/`fromDevice` (in).
public struct KeyEnvelope: Codable, Sendable, Equatable {
    public var epoch: UInt32
    public var fromDevice: String
    public var toDevice: String
    public var blob: Data

    public init(epoch: UInt32, fromDevice: String, toDevice: String, blob: Data) {
        self.epoch = epoch
        self.fromDevice = fromDevice
        self.toDevice = toDevice
        self.blob = blob
    }
}

/// A call key sealer allowed in release builds (libsignal). Fakes must stay inside `#if DEBUG`.
public protocol ReleaseCallKeySealer: CallKeySealer {}
