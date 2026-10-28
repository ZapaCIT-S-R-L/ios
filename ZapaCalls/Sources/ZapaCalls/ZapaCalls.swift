/// ZapaCalls: voice calls between the parents and kids of a family (1:1 and groups of up to 8).
///
/// - Media goes through Cloudflare Realtime (SFU + TURN). Every audio frame is encrypted on the phone with
///   AES-GCM (WebRTC FrameCryptor), with a random per-call key that `CallKeyManager` rotates on every join and leave.
/// - Keys travel sealed per recipient device (`CallKeySealer`, libsignal in the app); the calls service only relays
///   opaque blobs and never sees a key.
public enum ZapaCalls {}
