import SwiftUI
import ZapaCalls
import ZapaKidKit

/// The parent's family: parents, kids (robot, nickname, grade), add a kid, pair a kid's phone, invite the
/// second parent.
struct FamilyView: View {
    let model: FamilyModel
    @State private var addingKid = false
    @State private var pairing: FamilyModel.Pairing?
    @State private var invitation: FamilyModel.Invitation?

    var body: some View {
        List {
            if let family = model.family {
                Section {
                    ForEach(family.parents) { parent in
                        Label {
                            Text(verbatim: parent.displayName ?? "—")
                        } icon: {
                            Image(systemName: "person.fill")
                        }
                    }
                    Button {
                        Task { invitation = await model.inviteParent() }
                    } label: {
                        Label("Invite the other parent", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("family.inviteParent")
                } header: {
                    Text("Parents")
                }
                Section {
                    ForEach(family.kids) { kid in
                        kidRow(kid)
                    }
                    Button {
                        addingKid = true
                    } label: {
                        Label("Add a kid", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("family.addKid")
                } header: {
                    Text("Kids")
                }
            } else if model.isBusy {
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("family.error")
            }
        }
        .navigationTitle(Text("Family"))
        .task { await model.load() }
        .sheet(isPresented: $addingKid) {
            AddKidView(model: model)
        }
        .sheet(item: $pairing) { pairing in
            PairingQRView(pairing: pairing)
        }
        .sheet(item: $invitation) { invitation in
            InviteParentView(invitation: invitation)
        }
        .accessibilityIdentifier("family.screen")
    }

    private func kidRow(_ kid: Kid) -> some View {
        HStack(spacing: 12) {
            RobotAvatarView(avatar: kid.avatar, size: 44)
            VStack(alignment: .leading) {
                Text(verbatim: kid.nickname)
                    .font(.headline)
                GradeText.text(kid.grade)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { pairing = await model.pairing(for: kid) }
            } label: {
                Label("Pair phone", systemImage: "qrcode")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("family.kid.\(kid.nickname).pair")
        }
    }
}

extension FamilyModel.Pairing: @retroactive Identifiable {
    public var id: String {
        link.code
    }
}

extension FamilyModel.Invitation: @retroactive Identifiable {
    public var id: String {
        url.absoluteString
    }
}

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
