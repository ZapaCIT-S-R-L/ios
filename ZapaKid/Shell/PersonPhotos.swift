import Contacts
import ContactsUI
import SwiftUI
import ZapaCalls

/// Photos chosen from this phone's contacts, one per person (by account id). They stay on this phone only and are
/// left out of backups; without one, the person shows their robot.
@MainActor
@Observable
final class PersonPhotos {
    static let shared = PersonPhotos()

    private(set) var images: [String: UIImage] = [:]
    private let folder: URL

    init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = base.appending(path: "person-photos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = self.folder
        try? excluded.setResourceValues(values)
        let files = (try? FileManager.default.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                images[file.deletingPathExtension().lastPathComponent] = image
            }
        }
    }

    func image(for accountId: String) -> UIImage? {
        images[accountId]
    }

    /// Stores a JPEG for this person, or removes their photo when `jpeg` is nil.
    func set(_ jpeg: Data?, for accountId: String) {
        let file = folder.appending(path: "\(accountId).jpg")
        guard let jpeg, let image = UIImage(data: jpeg) else {
            try? FileManager.default.removeItem(at: file)
            images[accountId] = nil
            return
        }
        try? jpeg.write(to: file, options: .atomic)
        images[accountId] = image
    }
}

/// A person's photo if they have one on this phone, otherwise their robot.
struct PersonAvatar: View {
    let accountId: String?
    let avatar: String
    let size: CGFloat

    var body: some View {
        if let accountId, let photo = PersonPhotos.shared.image(for: accountId) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            RobotAvatarView(avatar: avatar, size: size)
        }
    }
}

/// The system contact picker, returning the chosen contact's photo as a JPEG (nil when the contact has none).
struct ContactPhotoPicker: UIViewControllerRepresentable {
    let onPick: (Data?) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (Data?) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (Data?) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            // Only read the photo when the picker actually returned it; reading an unfetched key would raise.
            guard contact.isKeyAvailable(CNContactImageDataKey), let raw = contact.imageData else {
                onPick(nil)
                return
            }
            onPick(ImageScrubber.jpeg(raw))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }
    }
}
