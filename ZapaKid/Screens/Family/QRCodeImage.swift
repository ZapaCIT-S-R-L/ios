import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code drawn on the phone (CoreImage); the code never leaves the app as an image file.
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

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
