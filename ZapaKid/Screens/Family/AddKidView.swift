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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $nickname) { Text("Nickname") }
                        .textContentType(.nickname)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("addKid.nickname")
                } footer: {
                    Text("Only a nickname. No real names, birthdays or photos.")
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await model.addKid(nickname: nickname, avatar: avatar, grade: grade) {
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
