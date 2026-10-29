import CoreImage
import Foundation
import Testing
@testable import ZapaKid
import ZapaKidKit

/// The pairing QR carries the robot in its centre; it must still scan back to the exact link.
@MainActor
struct QRCodeImageTests {
    private func decode(_ image: UIImage) -> String? {
        guard let cgImage = image.cgImage,
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
        else { return nil }
        let features = detector.features(in: CIImage(cgImage: cgImage))
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    @Test func theLongestPairingLinkScansBackWithTheRobotInTheCentre() throws {
        let link = PairingLink(code: "zkp_" + String(repeating: "A1b2C3d4", count: 6), fingerprint: String(repeating: "ab", count: 32))
        let image = try #require(QRCodeImage.render(link.url.absoluteString))
        #expect(decode(image) == link.url.absoluteString)
    }

    @Test func theRobotCoversAtMostAFifthOfTheWidth() {
        #expect(QRCodeImage.logoFraction <= 0.2)
    }
}
