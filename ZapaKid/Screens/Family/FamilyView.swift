import PhotosUI
import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Which person's photo is being chosen.
struct PhotoTarget: Identifiable {
    let id: String
}

/// The parent's family: parents, kids (robot, nickname, grade), add a kid, pair a kid's phone, invite the
/// second parent.
struct FamilyView: View {
    let model: FamilyModel
    /// The other families this one is connected to; nil when that screen isn't wired.
    var connections: ConnectionsModel?
    @State private var connectingFamily = false
    @State private var acceptingFamily = false
    @State private var editingKidId: String?
    /// A kid to open straight away (from a chat's kid name); cleared once opened.
    var pendingKid: String?
    var onKidEditOpened: () -> Void = {}
    @State private var addingKid = false
    @State private var pairing: FamilyModel.Pairing?
    @State private var invitation: FamilyModel.Invitation?
    @State private var renaming = false
    @State private var photoFor: PhotoTarget?
    @State private var noPhoto = false
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
                        Label("Invite another adult", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("family.inviteParent")
                } header: {
                    Text("Adults").foregroundStyle(theme.accent.color)
                }
                .listRowBackground(Color(white: 0.12))
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
                .listRowBackground(Color(white: 0.12))
                if let connections {
                    Section {
                        ForEach(connections.connections) { connection in
                            connectionBlock(connection, kids: family.kids, model: connections)
                        }
                        Button {
                            connectingFamily = true
                        } label: {
                            Label("Connect with another family", systemImage: "link.badge.plus")
                        }
                        .accessibilityIdentifier("family.connect")
                        Button {
                            acceptingFamily = true
                        } label: {
                            Label("Enter a code from another family", systemImage: "qrcode.viewfinder")
                        }
                        .accessibilityIdentifier("family.acceptConnection")
                    } header: {
                        Text("Other families").foregroundStyle(theme.accent.color)
                    }
                    .listRowBackground(Color(white: 0.12))
                }
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
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .modifier(ZapaTopBar(title: "Settings"))
        .task {
            await model.load()
            await connections?.load()
        }
        .onAppear {
            if let pendingKid {
                editingKidId = pendingKid
                onKidEditOpened()
            }
        }
        .onChange(of: pendingKid) { _, kidId in
            if let kidId {
                editingKidId = kidId
                onKidEditOpened()
            }
        }
        .navigationDestination(item: $editingKidId) { kidId in
            KidDetailView(model: model, kidId: kidId)
        }
        .sheet(isPresented: $connectingFamily) {
            if let connections {
                ConnectInviteView(connections: connections).zapaTheme(theme.role)
            }
        }
        .sheet(isPresented: $acceptingFamily) {
            if let connections {
                AcceptConnectionView(connections: connections).zapaTheme(theme.role)
            }
        }
        .sheet(isPresented: $addingKid) {
            AddKidView(model: model).zapaTheme(theme.role)
        }
        .sheet(item: $pairing) { pairing in
            PairingQRView(pairing: pairing).zapaTheme(theme.role)
        }
        .sheet(item: $invitation) { invitation in
            InviteParentView(invitation: invitation).zapaTheme(theme.role)
        }
        .sheet(isPresented: $renaming) {
            RenameView(model: model).zapaTheme(theme.role)
        }
        .sheet(item: $photoFor) { target in
            ContactPhotoPicker(
                onPick: { data in
                    photoFor = nil
                    if let data {
                        PersonPhotos.shared.set(data, for: target.id)
                    } else {
                        noPhoto = true
                    }
                },
                onCancel: { photoFor = nil }
            )
            .ignoresSafeArea()
        }
        .alert("That contact has no photo", isPresented: $noPhoto) {
            Button("OK") {}
        }
        .accessibilityIdentifier("family.screen")
    }
}

// MARK: Rows and connections

extension FamilyView {
    /// One connected family: which of your kids it can see (one, some or all), and disconnecting.
    private func connectionBlock(
        _ connection: Connection,
        kids: [Kid],
        model connections: ConnectionsModel
    ) -> some View {
        let shared = Set(connection.sharedKids.mine)
        return VStack(alignment: .leading, spacing: 10) {
            let names = connection.family.parents.compactMap(\.displayName)
            Text(verbatim: names.isEmpty ? String(localized: "Other family") : names.joined(separator: ", "))
                .font(.headline)
                .foregroundStyle(.white)
            if !connection.sharedKids.theirs.isEmpty {
                let sharedText = connection.sharedKids.theirs.map(\.nickname).joined(separator: ", ")
                Text("Shares with you: \(sharedText)")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            if kids.isEmpty {
                Text("Add a kid to share them.")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            } else {
                Text("Your kids they can see")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                shareToggles(connection, kids: kids, shared: shared, model: connections)
            }
            Button(role: .destructive) {
                Task { await connections.remove(connection.id) }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("family.disconnect")
        }
        .padding(.vertical, 6)
    }

    /// The "All kids" switch and one switch per kid, for what this connected family can see.
    @ViewBuilder private func shareToggles(
        _ connection: Connection,
        kids: [Kid],
        shared: Set<String>,
        model connections: ConnectionsModel
    ) -> some View {
        let allShared = !kids.isEmpty && kids.allSatisfy { shared.contains($0.id) }
        Toggle(isOn: Binding(
            get: { allShared },
            set: { isShared in
                Task {
                    for kid in kids where shared.contains(kid.id) != isShared {
                        await connections.setShared(isShared, kidId: kid.id, in: connection.id)
                    }
                }
            }
        )) {
            Text("All kids").foregroundStyle(.white)
        }
        .tint(theme.accent.color)
        ForEach(kids) { kid in
            Toggle(isOn: Binding(
                get: { shared.contains(kid.id) },
                set: { isShared in
                    Task { await connections.setShared(isShared, kidId: kid.id, in: connection.id) }
                }
            )) {
                Text(verbatim: kid.nickname).foregroundStyle(.white)
            }
            .tint(theme.accent.color)
            .accessibilityIdentifier("family.share.\(kid.nickname)")
        }
    }

    /// The green pencil next to each person you can edit.
    private var pencilBubble: some View {
        Image(systemName: "pencil")
            .font(.headline)
            .foregroundStyle(theme.onPrimary.color)
            .frame(width: 36, height: 36)
            .background(Circle().fill(theme.accent.color))
            .accessibilityLabel(Text("Edit"))
    }

    /// Long-press a person's picture: choose their photo from contacts, or go back to the robot.
    @ViewBuilder private func photoMenu(_ accountId: String) -> some View {
        Button { photoFor = PhotoTarget(id: accountId) } label: {
            Label("Choose photo from contacts", systemImage: "person.crop.circle.badge.plus")
        }
        if PersonPhotos.shared.image(for: accountId) != nil {
            Button(role: .destructive) { PersonPhotos.shared.set(nil, for: accountId) } label: {
                Label("Use the robot again", systemImage: "face.smiling")
            }
        }
    }

    private func parentRow(_ parent: FamilyParent, editable: Bool) -> some View {
        HStack(spacing: 12) {
            PersonAvatar(accountId: parent.id, avatar: "robot-2", size: 44)
                .contextMenu { photoMenu(parent.id) }
            VStack(alignment: .leading) {
                Text(verbatim: parent.displayName ?? "—")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Parent")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            Spacer()
            if editable {
                pencilBubble
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func kidRow(_ kid: Kid) -> some View {
        HStack(spacing: 12) {
            PersonAvatar(accountId: kid.id, avatar: kid.avatar, size: 44)
                .contextMenu { photoMenu(kid.id) }
            VStack(alignment: .leading) {
                Text(verbatim: kid.nickname)
                    .font(.headline)
                    .foregroundStyle(.white)
                GradeText.text(kid.grade)
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            Spacer()
            Button {
                editingKidId = kid.id
            } label: {
                pencilBubble
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit \(kid.nickname)"))
            .accessibilityIdentifier("family.kid.\(kid.nickname).edit")
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
