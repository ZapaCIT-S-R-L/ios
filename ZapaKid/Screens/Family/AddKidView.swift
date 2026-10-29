import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Add a kid: a nickname, a robot and a grade. Nothing else is stored about a kid.
struct AddKidView: View {
    let model: FamilyModel
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var avatar = "robot-1"
    @State private var grade: Int?
    @State private var photo: Data?
    @State private var choosingPhoto = false
    @State private var noPhoto = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $nickname) { Text("Nickname") }
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("addKid.nickname")
                } footer: {
                    Text("Only a nickname and no birthdays. A photo, if you add one, stays on this phone.")
                }
                Section {
                    Button { choosingPhoto = true } label: {
                        Label("Choose from contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("addKid.photo")
                    if photo != nil {
                        Button(role: .destructive) { photo = nil } label: {
                            Label("Remove photo", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Photo")
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                        ForEach(RobotAvatarStyle.all, id: \.index) { style in
                            robotButton("robot-\(style.index)", number: style.index)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Robot")
                }
                Section {
                    Picker(selection: $grade) {
                        ForEach(GradeText.all, id: \.self) { grade in
                            GradeText.text(grade).tag(grade)
                        }
                    } label: {
                        Text("Grade")
                    }
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle(Text("Add a kid"))
            .sheet(isPresented: $choosingPhoto) {
                ContactPhotoPicker(
                    onPick: { data in
                        choosingPhoto = false
                        if let data {
                            photo = data
                        } else {
                            noPhoto = true
                        }
                    },
                    onCancel: { choosingPhoto = false }
                )
                .ignoresSafeArea()
            }
            .alert("That contact has no photo", isPresented: $noPhoto) {
                Button("OK") {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await model.addKid(nickname: nickname, avatar: avatar, grade: grade) {
                                // addKid appends the new kid, so the last one is theirs.
                                if let photo, let id = model.family?.kids.last?.id {
                                    PersonPhotos.shared.set(photo, for: id)
                                }
                                dismiss()
                            }
                        }
                    } label: {
                        Text("Save")
                    }
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
                    .accessibilityIdentifier("addKid.save")
                }
            }
        }
    }

    private func robotButton(_ name: String, number: Int) -> some View {
        Button {
            avatar = name
        } label: {
            RobotAvatarView(avatar: name, size: 56)
                .padding(4)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: avatar == name ? 4 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Robot \(number)"))
        .accessibilityAddTraits(avatar == name ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("addKid.avatar.\(name)")
    }
}
