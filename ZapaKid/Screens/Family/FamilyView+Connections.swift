import PhotosUI
import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Connect with another family: a one-time code as a QR code and a link, valid 72 hours, works once.
struct ConnectInviteView: View {
    let connections: ConnectionsModel
    @State private var invitation: ConnectionInvitation?
    @State private var asked = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let invitation, let link = invitation.link {
                    QRCodeImage(text: link.absoluteString, label: Text("Connection code"))
                        .frame(width: 240, height: 240)
                    Text("Let the other family scan this, or send them the link. It works once, for 72 hours.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.gray)
                    ShareLink(item: link) {
                        Label("Share the link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("family.connect.share")
                } else if let message = connections.errorMessage {
                    Text(message).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(Text("Connect a family"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done") }
                }
            }
            .task {
                guard !asked else { return }
                asked = true
                invitation = await connections.invite()
            }
        }
    }
}

/// Connect with a family that showed you its code: scan it or paste the code or link.
struct AcceptConnectionView: View {
    let connections: ConnectionsModel
    @State private var text = ""
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if QRScanner.isAvailable {
                    Section {
                        Button { scanning = true } label: {
                            Label("Scan their code", systemImage: "qrcode.viewfinder")
                        }
                        .accessibilityIdentifier("family.accept.scan")
                    }
                }
                Section {
                    TextField(text: $text, axis: .vertical) { Text("Code or link") }
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("family.accept.code")
                    Button {
                        Task { await accept(text) }
                    } label: {
                        Text("Connect")
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || connections.isBusy)
                    .accessibilityIdentifier("family.accept.connect")
                } footer: {
                    Text("Only connect with a family you know. You choose which kids they can see.")
                }
                if let message = connections.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle(Text("Connect a family"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                }
            }
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    Task { await accept(code) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func accept(_ code: String) async {
        if await connections.accept(code: code) {
            dismiss()
        }
    }
}
