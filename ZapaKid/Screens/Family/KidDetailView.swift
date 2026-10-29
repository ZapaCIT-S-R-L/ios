import PhotosUI
import SwiftUI
import ZapaCalls
import ZapaKidKit

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
