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

    /// One connected family: which of your kids it can see (one, some or all), and disconnecting.
    private func connectionBlock(
        _ connection: Connection,
        kids: [Kid],
        model connections: ConnectionsModel
    ) -> some View {
        let shared = Set(connection.sharedKids.mine)
        let allShared = !kids.isEmpty && kids.allSatisfy { shared.contains($0.id) }
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
                Toggle(isOn: Binding(
                    get: { allShared },
                    set: { on in
                        Task {
                            for kid in kids where shared.contains(kid.id) != on {
                                await connections.setShared(on, kidId: kid.id, in: connection.id)
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
                        set: { on in
                            Task { await connections.setShared(on, kidId: kid.id, in: connection.id) }
                        }
                    )) {
                        Text(verbatim: kid.nickname).foregroundStyle(.white)
                    }
                    .tint(theme.accent.color)
                    .accessibilityIdentifier("family.share.\(kid.nickname)")
                }
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

    /// The green pencil next to each person you can edit.
    private var pencilBubble: some View {
        Image(systemName: "pencil")
            .font(.headline)
            .foregroundStyle(theme.onPrimary.color)
            .frame(width: 36, height: 36)
            .background(Circle().fill(theme.accent.color))
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

/// One kid: their name, robot or photo, pairing a phone, and removing them from the family.
struct KidDetailView: View {
    let model: FamilyModel
    let kidId: String
    @State private var nickname = ""
    @State private var avatar = "robot-1"
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showContacts = false
    @State private var pairing: FamilyModel.Pairing?
    @State private var confirmRemove = false
    @State private var noPhoto = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.zapaTheme) private var theme

    private var kid: Kid? {
        model.family?.kids.first { $0.id == kidId }
    }

    var body: some View {
        Form {
            if let kid {
                Section {
                    VStack(spacing: 12) {
                        PersonAvatar(accountId: kid.id, avatar: avatar, size: 120)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                Section {
                    Button { showPhotos = true } label: {
                        Label("Choose a photo", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("kid.photo")
                    Button { showContacts = true } label: {
                        Label("Link to a contact", systemImage: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("kid.contact")
                    if PersonPhotos.shared.image(for: kid.id) != nil {
                        Button(role: .destructive) { PersonPhotos.shared.set(nil, for: kid.id) } label: {
                            Label("Use the robot avatar", systemImage: "face.smiling")
                        }
                        .accessibilityIdentifier("kid.useRobot")
                    }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("A photo stays on this phone.")
                }
                // With a photo or contact linked, the robots stay hidden until "Use the robot avatar".
                if PersonPhotos.shared.image(for: kid.id) == nil {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                            ForEach(RobotAvatarStyle.all, id: \.index) { style in
                                let name = "robot-\(style.index)"
                                Button { avatar = name } label: {
                                    RobotAvatarView(avatar: name, size: 56)
                                        .padding(4)
                                        .overlay(Circle().strokeBorder(
                                            theme.accent.color,
                                            lineWidth: avatar == name ? 4 : 0
                                        ))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Robot \(style.index)"))
                                .accessibilityAddTraits(avatar == name ? [.isSelected, .isButton] : .isButton)
                            }
                        }
                        .padding(.vertical, 8)
                    } header: {
                        Text("Robot")
                    }
                }
                Section {
                    TextField(text: $nickname) { Text("Nickname") }
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("kid.nickname")
                } header: {
                    Text("Name")
                }
                Section {
                    Button {
                        // Only a changed name or robot goes to the server; a photo or contact stays on this phone.
                        guard nickname != kid.nickname || avatar != kid.avatar else {
                            dismiss()
                            return
                        }
                        Task {
                            if await model.renameKid(kid, nickname: nickname, avatar: avatar) {
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Save")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("kid.save")
                }
                Section {
                    Button {
                        Task { pairing = await model.pairing(for: kid) }
                    } label: {
                        Label("Pair phone", systemImage: "qrcode")
                    }
                    .accessibilityIdentifier("family.kid.\(kid.nickname).pair")
                }
                Section {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("Remove from family", systemImage: "trash")
                    }
                    .accessibilityIdentifier("kid.remove")
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(theme.danger.color)
                }
            }
        }
        .navigationTitle(Text(verbatim: kid?.nickname ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let kid {
                nickname = kid.nickname
                avatar = kid.avatar
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = ImageScrubber.jpeg(data) {
                    PersonPhotos.shared.set(jpeg, for: kidId)
                }
                photoItem = nil
            }
        }
        .sheet(isPresented: $showContacts) {
            ContactPhotoPicker(
                onPick: { data in
                    showContacts = false
                    if let data {
                        PersonPhotos.shared.set(data, for: kidId)
                    } else {
                        noPhoto = true
                    }
                },
                onCancel: { showContacts = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $pairing) { pairing in
            PairingQRView(pairing: pairing).zapaTheme(theme.role)
        }
        .confirmationDialog(
            "Remove this kid from the family?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove from family", role: .destructive) {
                Task {
                    if let kid, await model.removeKid(kid) {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Their account and phones are removed too. Their photo on this phone goes with them.")
        }
        .alert("That contact has no photo", isPresented: $noPhoto) {
            Button("OK") {}
        }
        .accessibilityIdentifier("kid.screen")
    }
}
