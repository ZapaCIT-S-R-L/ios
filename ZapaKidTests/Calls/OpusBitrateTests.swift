import Testing
@testable import ZapaCalls

/// The Opus bitrate cap written into the SDP (`maxaveragebitrate`, in bits per second).
struct OpusBitrateTests {
    let offer = """
    v=0\r
    m=audio 9 UDP/TLS/RTP/SAVPF 111 103\r
    a=rtpmap:111 opus/48000/2\r
    a=fmtp:111 minptime=10;useinbandfec=1\r
    a=rtpmap:103 ISAC/16000\r

    """

    @Test func theCapGoesIntoTheOpusFmtpLine() {
        let capped = OpusBitrate.capping(offer, kbps: 24)

        #expect(capped.contains("a=fmtp:111 minptime=10;useinbandfec=1;maxaveragebitrate=24000\r\n"))
    }

    @Test func aMissingFmtpLineIsAddedAfterTheRtpmap() {
        let bare = offer.replacingOccurrences(of: "a=fmtp:111 minptime=10;useinbandfec=1\r\n", with: "")

        let capped = OpusBitrate.capping(bare, kbps: 48)

        #expect(capped.contains("a=rtpmap:111 opus/48000/2\r\na=fmtp:111 maxaveragebitrate=48000\r\n"))
    }

    @Test func zeroLeavesTheSdpAsItIs() {
        #expect(OpusBitrate.capping(offer, kbps: 0) == offer)
    }

    @Test func otherCodecsAreNotTouched() {
        let capped = OpusBitrate.capping(offer, kbps: 24)

        #expect(capped.contains("a=rtpmap:103 ISAC/16000"))
        #expect(!capped.contains("a=fmtp:103"))
    }
}
