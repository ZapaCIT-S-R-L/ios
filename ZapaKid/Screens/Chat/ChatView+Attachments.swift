import AVFoundation
import AVKit
import Contacts
import ContactsUI
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZapaCalls
import ZapaChat

/// The system contact picker. Only the contact the person taps is shared.
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (ContactCard) -> Void
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
        let onPick: (ContactCard) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (ContactCard) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let card = ContactCard(
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                phones: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { String($0.value) }
            )
            onPick(card)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }
    }
}

/// One fix of the phone's position, asked for once; asks for permission the first time.
final class LocationFinder: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: finish(.failure(CocoaError(.userCancelled)))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if continuation != nil {
                manager.requestLocation()
            }
        case .denied, .restricted:
            finish(.failure(CocoaError(.userCancelled)))
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let here = locations.last {
            finish(.success(here))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// A photo, decrypted on the phone.
struct AttachmentImage: View {
    let pointer: AttachmentPointer
    let services: AppServices
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text("Photo"))
            } else {
                ProgressView()
                    .frame(width: 120, height: 120)
                    .accessibilityLabel(Text("Photo"))
            }
        }
        .task {
            if let data = try? await services.chat.attachmentData(pointer) {
                image = UIImage(data: data)
            }
        }
    }
}

/// A voice message: play/stop and its length.
struct VoiceNoteView: View {
    let pointer: AttachmentPointer
    let services: AppServices
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            HStack {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                Image(systemName: "waveform")
                Text(Duration.seconds(pointer.duration ?? 0).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Voice message"))
    }

    private func toggle() async {
        if playing {
            player?.stop()
            playing = false
            return
        }
        guard let data = try? await services.chat.attachmentData(pointer),
              let player = try? AVAudioPlayer(data: data) else { return }
        self.player = player
        player.play()
        playing = true
    }
}

/// Records a voice message (AAC, mono) into memory; the file is deleted right after.
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var url: URL?

    struct Note {
        let data: Data
        let duration: Double
    }

    func start() {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1,
        ]
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record(forDuration: 120) else { return }
            self.recorder = recorder
            self.url = url
            isRecording = true
        } catch {
            isRecording = false
        }
    }

    func stop() -> Note? {
        guard let recorder, let url else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        isRecording = false
        self.recorder = nil
        self.url = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard duration >= 0.5, let data = try? Data(contentsOf: url) else { return nil }
        return Note(data: data, duration: duration)
    }
}

/// Re-encodes a photo as JPEG, which drops EXIF (location, camera) before it is encrypted.
enum ImageScrubber {
    static func jpeg(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
