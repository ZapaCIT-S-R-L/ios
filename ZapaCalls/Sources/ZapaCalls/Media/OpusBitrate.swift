import Foundation

/// Caps the Opus bitrate that WebRTC negotiates for call audio (`maxaveragebitrate` in the SDP fmtp line).
/// Only the Debug build reads the setting (`-zkOpusKbps 24` as a launch argument); release builds keep WebRTC's
/// default.
public enum OpusBitrate {
    /// The cap in kbps for this launch, or 0 for WebRTC's default.
    public static var configuredKbps: Int {
        #if DEBUG
            UserDefaults.standard.integer(forKey: "zkOpusKbps")
        #else
            0
        #endif
    }

    /// The SDP with `maxaveragebitrate` set on every Opus payload; unchanged when `kbps` is 0.
    public static func capping(_ sdp: String, kbps: Int) -> String {
        guard kbps > 0 else { return sdp }
        let lines = sdp.components(separatedBy: "\r\n")
        let opus = lines.filter { $0.hasPrefix("a=rtpmap:") && $0.hasSuffix("opus/48000/2") }
            .compactMap { $0.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init) }
        guard !opus.isEmpty else { return sdp }
        let cap = "maxaveragebitrate=\(kbps * 1000)"
        var out = lines
        for payload in opus {
            if let index = out.firstIndex(where: { $0.hasPrefix("a=fmtp:\(payload) ") }) {
                out[index] += ";\(cap)"
            } else if let index = out.firstIndex(where: { $0.hasPrefix("a=rtpmap:\(payload) ") }) {
                out.insert("a=fmtp:\(payload) \(cap)", at: index + 1)
            }
        }
        return out.joined(separator: "\r\n")
    }
}
