import PhotosUI
import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Shows the pairing QR for 5 minutes; the kid's phone scans it in ZapaKid.
struct PairingQRView: View {
    let pairing: FamilyModel.Pairing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    RobotAvatarView(avatar: pairing.kid.avatar, size: 72)
                    Text(verbatim: pairing.kid.nickname)
                        .font(.title.bold())
                    QRCodeImage(text: pairing.link.url.absoluteString, label: Text("Pairing QR code"))
                        .accessibilityIdentifier("pairing.qr")
                    Text("Open ZapaKid on your kid's phone, tap \"This is my kid's phone\" and scan this code.")
                        .multilineTextAlignment(.center)
                    HStack {
                        Text("Expires in")
                        Text(timerInterval: Date() ... max(Date(), pairing.expiresAt), countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done") }
                }
            }
        }
    }
}

/// The co-parent invitation as a QR code and a link to share (valid 3 days, works once).
struct InviteParentView: View {
    let invitation: FamilyModel.Invitation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    QRCodeImage(text: invitation.url.absoluteString, label: Text("Invitation QR code"))
                        .accessibilityIdentifier("invite.qr")
                    Text("The other parent signs in to ZapaKid and scans this code, or opens the link.")
                        .multilineTextAlignment(.center)
                    ShareLink(item: invitation.url) {
                        Label("Share invitation", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("invite.share")
                    Text("Valid for 3 days. It works once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done") }
                }
            }
        }
    }
}

/// The signed-in parent changes the name the family sees.
struct RenameView: View {
    let model: FamilyModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text("Your name") }
                        .textContentType(.name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("rename.name")
                } footer: {
                    Text("Family members see this name.")
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                        .accessibilityIdentifier("rename.error")
                }
            }
            .navigationTitle(Text("Change your name"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await model.rename(to: name) {
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Save")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                    .accessibilityIdentifier("rename.save")
                }
            }
            .onAppear {
                name = model.family?.parents.first { model.canRename($0) }?.displayName ?? ""
            }
        }
    }
}
