import SwiftUI
import VisionKit
import ZapaCalls
import ZapaKidKit

/// The kid's phone: scan the parent's QR code (camera) or type the code.
struct PairPhoneView: View {
    let model: KidPairingModel
    @State private var code = ""
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Ask your parent to show the QR code in ZapaKid (Family, Pair phone).")
                    .multilineTextAlignment(.center)
                if QRScanner.isAvailable {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan the QR code", systemImage: "camera.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pair.scan")
                }
                TextField(text: $code) { Text("Or type the code") }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pair.code")
                Button {
                    Task { await model.redeem(scanned: code) }
                } label: {
                    Text("Pair this phone")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .disabled(code.isEmpty || model.isBusy)
                .accessibilityIdentifier("pair.submit")
                if model.isBusy {
                    ProgressView()
                        .accessibilityLabel(Text("Pairing"))
                }
                if let message = model.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("pair.error")
                }
            }
            .padding(24)
        }
        .navigationTitle(Text("Kid's phone"))
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                Task { await model.redeem(scanned: text) }
            }
            .ignoresSafeArea()
        }
        .accessibilityIdentifier("pair.screen")
    }
}

/// VisionKit's QR scanner (camera; the permission text is in the Info.plist).
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_: DataScannerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_: DataScannerViewController, didAdd items: [RecognizedItem], allItems _: [RecognizedItem]) {
            guard !done else { return }
            for case let .barcode(code) in items {
                if let text = code.payloadStringValue {
                    done = true
                    onCode(text)
                    return
                }
            }
        }
    }
}
