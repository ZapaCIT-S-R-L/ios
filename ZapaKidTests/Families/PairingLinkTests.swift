import Foundation
import Testing
@testable import ZapaKidKit

/// The kid pairing QR (`zapakid://pair?code=<code>&fp=<parent identity fingerprint>`) and the co-parent invitation
/// link (`https://zapakid.ro/join#<code>`; the fragment never reaches a server log).
struct PairingLinkTests {
    let code = "zkp_" + String(repeating: "A", count: 43)
    let fingerprint = String(repeating: "ab", count: 32)

    @Test func pairingQRRoundTrips() {
        let link = PairingLink(code: code, fingerprint: fingerprint)

        #expect(link.url.absoluteString == "zapakid://pair?code=\(code)&fp=\(fingerprint)")
        #expect(PairingLink(scanned: link.url.absoluteString) == link)
    }

    @Test func aBareCodeIsAcceptedWithoutFingerprint() {
        #expect(PairingLink(scanned: "  \(code)\n") == PairingLink(code: code, fingerprint: nil))
    }

    @Test(arguments: [
        "https://evil.example/pair?code=zkp_x",
        "zapakid://pair?code=zkp_short",
        "zapakid://pair?fp=abcd",
        "zapakid://other?code=zkp_" + String(repeating: "A", count: 43),
        "zki_" + String(repeating: "A", count: 43),
    ])
    func otherQRCodesAreRefused(text: String) {
        #expect(PairingLink(scanned: text) == nil)
    }

    @Test func aBadFingerprintIsDropped() {
        let link = PairingLink(scanned: "zapakid://pair?code=\(code)&fp=nothex")
        #expect(link?.fingerprint == nil)
    }

    @Test func invitationLinksKeepTheCodeInTheFragment() {
        let invite = "zki_" + String(repeating: "Z", count: 43)

        let url = InvitationLink.url(code: invite)

        #expect(url.absoluteString == "https://zapakid.ro/join#\(invite)")
        #expect(InvitationLink.code(from: url.absoluteString) == invite)
        #expect(InvitationLink.code(from: invite) == invite)
        #expect(InvitationLink.code(from: "https://zapakid.ro/join?code=\(invite)") == nil)
    }

    @Test func fingerprintsAreSHA256Hex() {
        #expect(IdentityFingerprint.hex(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
