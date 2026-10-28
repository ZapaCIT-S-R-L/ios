import CryptoKit
import Foundation

/// One epoch's frame key: 32 random bytes that WebRTC's FrameCryptor (AES-GCM) encrypts every audio frame with.
/// A new key, with the next epoch, on every join and leave. Never logged: descriptions show only the epoch.
public struct CallKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let byteCount = 32
    /// Keys the frame cryptor keeps at once; each frame carries `epoch % ringSize` as its key index, so frames
    /// still in flight under the previous key decrypt after a rotation.
    public static let ringSize = 16

    public let epoch: UInt32
    public let bytes: Data

    public init?(epoch: UInt32, bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.epoch = epoch
        self.bytes = bytes
    }

    public static func random(epoch: UInt32) -> CallKey {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // swiftlint:disable:next force_unwrapping
        return CallKey(epoch: epoch, bytes: bytes)!
    }

    public static func ringIndex(forEpoch epoch: UInt32) -> Int {
        Int(epoch % UInt32(ringSize))
    }

    public var ringIndex: Int {
        Self.ringIndex(forEpoch: epoch)
    }

    public var description: String {
        "CallKey(epoch: \(epoch))"
    }

    public var debugDescription: String {
        description
    }
}

public enum CallKeyError: Error, Equatable, Sendable {
    case malformed
    case wrongCall
    case wrongEpoch
    case notForMe
}

/// What gets sealed per recipient device: the key bound to its call and epoch, so a blob can't be replayed into
/// another call or epoch. Layout (big-endian), the same on Android:
/// `"ZKCK" | version 1 | epoch u32 | key 32 bytes | callId UTF-8`.
public enum CallKeyMaterial {
    static let magic = Data("ZKCK".utf8)
    static let version: UInt8 = 1

    public static func encode(_ key: CallKey, callId: String) -> Data {
        var data = magic
        data.append(version)
        withUnsafeBytes(of: key.epoch.bigEndian) { data.append(contentsOf: $0) }
        data.append(key.bytes)
        data.append(Data(callId.utf8))
        return data
    }

    public static func decode(_ data: Data, callId: String, epoch: UInt32) throws -> CallKey {
        let bytes = [UInt8](data)
        let header = magic.count + 1 + 4
        guard bytes.count > header + CallKey.byteCount, Data(bytes[0 ..< magic.count]) == magic,
              bytes[magic.count] == version
        else { throw CallKeyError.malformed }
        let sealedEpoch = bytes[(magic.count + 1) ..< header].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let keyBytes = Data(bytes[header ..< header + CallKey.byteCount])
        let sealedCall = Data(bytes[(header + CallKey.byteCount)...])
        guard sealedCall == Data(callId.utf8) else { throw CallKeyError.wrongCall }
        guard sealedEpoch == epoch else { throw CallKeyError.wrongEpoch }
        guard let key = CallKey(epoch: epoch, bytes: keyBytes) else { throw CallKeyError.malformed }
        return key
    }
}
