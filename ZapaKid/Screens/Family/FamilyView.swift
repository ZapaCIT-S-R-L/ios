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
    @State private var renaming = false
    @State private var editing: Kid?
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        List {
            if let family = model.family {
                Section {
                    ForEach(family.parents) { parent in
                        if model.canRename(parent) {
                            Button {
                                renaming = true
                            } label: {
                                parentRow(parent, editable: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Change your name"))
                            .accessibilityIdentifier("family.me")
                        } else {
                            parentRow(parent, editable: false)
                        }
                    }
                    Button {
                        Task { invitation = await model.inviteParent() }
                    } label: {
                        Label("Invite the other parent", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("family.inviteParent")
                } header: {
                    Text("Parents").foregroundStyle(theme.accent.color)
                }
                .listRowBackground(theme.surface.color)
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
                    Text("Kids").foregroundStyle(theme.accent.color)
                }
                .listRowBackground(theme.surface.color)
            } else if model.isBusy {
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            }
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(theme.danger.color)
                    .accessibilityIdentifier("family.error")
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.background.color.ignoresSafeArea())
        .navigationTitle(Text("Family"))
        .task { await model.load() }
        .sheet(isPresented: $addingKid) {
            AddKidView(model: model).zapaTheme(theme.role)
        }
        .sheet(item: $pairing) { pairing in
            PairingQRView(pairing: pairing).zapaTheme(theme.role)
        }
        .sheet(item: $invitation) { invitation in
            InviteParentView(invitation: invitation).zapaTheme(theme.role)
        }
        .sheet(item: $editing) { kid in
            EditKidView(model: model, kid: kid).zapaTheme(theme.role)
        }
        .sheet(isPresented: $renaming) {
            RenameView(model: model).zapaTheme(theme.role)
        }
        .accessibilityIdentifier("family.screen")
    }

    private func parentRow(_ parent: FamilyParent, editable: Bool) -> some View {
        HStack(spacing: 12) {
            RobotAvatarView(avatar: "robot-2", size: 44)
            VStack(alignment: .leading) {
                Text(verbatim: parent.displayName ?? "—")
                    .font(.headline)
                    .foregroundStyle(theme.text.color)
                Text("Parent")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText.color)
            }
            Spacer()
            if editable {
                Image(systemName: "pencil")
                    .foregroundStyle(theme.secondaryText.color)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func kidRow(_ kid: Kid) -> some View {
        HStack(spacing: 12) {
            Button {
                editing = kid
            } label: {
                HStack(spacing: 12) {
                    RobotAvatarView(avatar: kid.avatar, size: 44)
                    VStack(alignment: .leading) {
                        Text(verbatim: kid.nickname)
                            .font(.headline)
                            .foregroundStyle(theme.text.color)
                        GradeText.text(kid.grade)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText.color)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Rename or remove"))
            .accessibilityIdentifier("family.kid.\(kid.nickname).edit")
            Spacer()
            Button {
                Task { pairing = await model.pairing(for: kid) }
            } label: {
                Label("Pair phone", systemImage: "qrcode")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.onPrimary.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(theme.primary.color))
            }
            .buttonStyle(.plain)
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
