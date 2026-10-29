import CoreImage.CIFilterBuiltins
import SwiftUI
import ZapaCalls

/// A QR code drawn on the phone (CoreImage) with the robot in the centre; the code never leaves the app as an
/// image file. Error correction H (30 %) leaves plenty of room for the tile.
struct QRCodeImage: View {
    let text: String
    let label: Text

    var body: some View {
        Group {
            if let image = Self.render(text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.white))
        .frame(maxWidth: 280)
        .accessibilityLabel(label)
    }

    /// The tile (white, rounded, robot inside) as a share of the QR width; H tolerates far more, scanners like less.
    static let logoFraction: CGFloat = 0.2

    @MainActor
    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        let width = CGFloat(cgImage.width)
        let tile = width * logoFraction
        let logo = ImageRenderer(content: RobotTile(size: tile))
        logo.scale = 1
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width), format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: width, height: width))
            logo.uiImage?.draw(in: CGRect(x: (width - tile) / 2, y: (width - tile) / 2, width: tile, height: tile))
        }
    }
}

private struct RobotTile: View {
    let size: CGFloat

    var body: some View {
        RobotAvatarView(avatar: "robot-1", size: size * 0.8)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color.white))
    }
}
