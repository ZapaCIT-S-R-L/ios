import AVKit
import AVFoundation
import Contacts
import ContactsUI
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZapaCalls
import ZapaChat

/// Largest file this phone sends (it is encrypted in memory first).
private let maxAttachmentBytes = 25 * 1024 * 1024

/// One chat: bubbles, a text field, a "+" for photos, videos, documents, contacts and location, voice messages
/// (hold the mic) and a big call button.
struct ChatView: View {
    let services: AppServices
    let conversation: Conversation
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showContacts = false
    @State private var problem: LocalizedStringKey?
    @State private var finder = LocationFinder()
    @State private var recorder = VoiceRecorder()
    @FocusState private var typing: Bool
    /// How many of the latest messages are shown; "Earlier messages" adds 50 more.
    @State private var shownCount = 50
    @Environment(\.zapaTheme) private var theme

    /// Under the top bar: a line, then a call's notice when there is one. The messages scroll beneath it.
    private var header: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(white: 0.2))
                .frame(height: 0.5)
            CallNoticeBar(services: services)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// In the top bar, in the middle: the person's picture (or robot) and name.
    private var principal: some View {
        HStack(spacing: 8) {
            PersonAvatar(
                accountId: services.otherMemberId(of: conversation),
                avatar: services.avatar(of: conversation), size: 32
            )
            if services.isParentPhone, let kidId = kidOfChat {
                // A parent taps a kid's name to edit that kid in Settings.
                Button {
                    services.pendingKidEdit = kidId
                } label: {
                    headerName
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.kidName")
            } else {
                headerName
            }
        }
    }

    private var headerName: some View {
        Text(verbatim: services.name(of: conversation))
            .font(.title2.bold())
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    /// The kid in a one-to-one chat, if the other member is one.
    private var kidOfChat: String? {
        guard let other = services.otherMemberId(of: conversation), services.people[other]?.role == .kid else {
            return nil
        }
        return other
    }

    private var messages: [ChatMessage] {
        services.chat.messages[conversation.id] ?? []
    }

    /// The latest messages on screen.
    private var visible: [ChatMessage] {
        Array(messages.suffix(shownCount))
    }

    var body: some View {
        ScrollViewReader { scroll in
            // The tap below only hides the keyboard; it is not a control (VoiceOver users have the keyboard's own
            // dismiss gesture), so it gets no button trait.
            // swiftlint:disable:next accessibility_trait_for_button
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.count > shownCount {
                        Button {
                            shownCount += 50
                        } label: {
                            Text("Earlier messages")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(theme.accent.color)
                        }
                        .accessibilityIdentifier("chat.earlier")
                    }
                    ForEach(visible) { message in
                        MessageBubble(message: message, services: services)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .background(theme.background.color.ignoresSafeArea())
            .scrollDismissesKeyboard(.immediately)
            // Without a Done bar, a tap on the messages hides the keyboard too, even when there's nothing to scroll.
            .simultaneousGesture(TapGesture().onEnded { typing = false })
            .accessibilityIdentifier("chat.messages")
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation { scroll.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // Once the keyboard is up, the last message moves above it.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if let last = visible.last {
                    withAnimation { scroll.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                // Open at the bottom, with the keyboard up and the text input focused.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if let last = visible.last {
                        scroll.scrollTo(last.id, anchor: .bottom)
                    }
                    typing = true
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        // The name is in the header below, not the navigation bar.
        .navigationTitle(Text(""))
        .navigationBarTitleDisplayMode(.inline)
        // The chats and settings tabs stay away while a conversation is open; back returns to the chats.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                principal
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await services.call(conversation) }
                } label: {
                    Label { Text("Call") } icon: { Image(systemName: "phone.fill") }
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
                        .foregroundStyle(theme.onPrimary.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.primary.color))
                }
                .accessibilityLabel(Text("Call"))
                .accessibilityIdentifier("chat.call")
                .disabled(conversation.state == .closed)
            }
        }
        .onAppear {
            services.chat.connect(conversation.id)
            services.chat.markRead(conversation.id)
        }
        .onChange(of: messages.count) { services.chat.markRead(conversation.id) }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await sendPicked(item) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { result in
            Task { await sendFile(result) }
        }
        .sheet(isPresented: $showContacts) {
            ContactPicker(
                onPick: { card in
                    showContacts = false
                    Task { await services.chat.send(body: .contact(card), in: conversation.id) }
                },
                onCancel: { showContacts = false }
            )
            .ignoresSafeArea()
        }
        .alert(
            "Can't send that",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    /// A picked photo (scrubbed to JPEG) or video, as sealed bytes.
    private func sendPicked(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            problem = "That photo couldn't be read."
            return
        }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard data.count <= maxAttachmentBytes else {
                problem = "Files up to 25 MB can be sent."
                return
            }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "video/quicktime"
            await services.chat.send(
                attachment: data, kind: .video, mimeType: mime, duration: nil, in: conversation.id
            )
        } else if let jpeg = ImageScrubber.jpeg(data) {
            await services.chat.send(
                attachment: jpeg, kind: .image, mimeType: "image/jpeg", duration: nil, in: conversation.id
            )
        } else {
            problem = "That photo couldn't be read."
        }
    }

    /// A document from Files, sent with its name.
    private func sendFile(_ result: Result<URL, Error>) async {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            problem = "That file couldn't be read."
            return
        }
        guard data.count <= maxAttachmentBytes else {
            problem = "Files up to 25 MB can be sent."
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        await services.chat.send(
            attachment: data, kind: .document, mimeType: mime, duration: nil, fileName: url.lastPathComponent,
            in: conversation.id
        )
    }

    /// The phone's position now, sent as coordinates.
    private func sendLocation() async {
        do {
            let here = try await finder.current()
            await services.chat.send(
                body: .location(Location(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)),
                in: conversation.id
            )
        } catch {
            problem = "Turn on location for ZapaKid in Settings to send where you are."
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Menu {
                Button { showPhotos = true } label: { Label("Photo or video", systemImage: "photo.on.rectangle") }
                    .accessibilityIdentifier("chat.attach.photo")
                Button { showFiles = true } label: { Label("Document", systemImage: "doc") }
                    .accessibilityIdentifier("chat.attach.document")
                Button { showContacts = true } label: { Label("Contact", systemImage: "person.crop.circle") }
                    .accessibilityIdentifier("chat.attach.contact")
                Button { Task { await sendLocation() } } label: {
                    Label("Current location", systemImage: "location.fill")
                }
                .accessibilityIdentifier("chat.attach.location")
            } label: {
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .foregroundStyle(theme.onPrimary.color)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(theme.primary.color))
                    .frame(width: theme.minTapTarget, height: theme.minTapTarget)
            }
            .accessibilityLabel(Text("Attach"))
            .accessibilityIdentifier("chat.attach")
            TextField(text: $text, axis: .vertical) { Text("Message") }
                .lineLimit(1 ... 5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(theme.surface.color))
                .overlay(Capsule().strokeBorder(theme.separator.color, lineWidth: theme.cardShadow ? 2 : 1))
                .foregroundStyle(theme.text.color)
                .focused($typing)
                .accessibilityIdentifier("chat.input")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(recorder.isRecording ? theme.danger.color : theme.accent.color)
                    .frame(width: theme.minTapTarget, height: theme.minTapTarget)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !recorder.isRecording {
                                recorder.start()
                            }
                        }
                        .onEnded { _ in
                            if let note = recorder.stop() {
                                Task {
                                    await services.chat.send(
                                        attachment: note.data, kind: .voice, mimeType: "audio/mp4",
                                        duration: note.duration, in: conversation.id
                                    )
                                }
                            }
                        })
                    .accessibilityElement()
                    .accessibilityLabel(Text("Hold to record a voice message"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("chat.voice")
            } else {
                Button {
                    let message = text
                    text = ""
                    Task { await services.chat.send(text: message, in: conversation.id) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(theme.accent.color)
                        .frame(width: theme.minTapTarget, height: theme.minTapTarget)
                }
                .accessibilityLabel(Text("Send"))
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background.color)
        .overlay(alignment: .top) { theme.separator.color.frame(height: 0.5) }
        .disabled(conversation.state == .closed)
    }
}

/// A message bubble: mine on the right, theirs on the left with their robot.
struct MessageBubble: View {
    let message: ChatMessage
    let services: AppServices
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isMine {
                Spacer(minLength: 48)
            } else {
                PersonAvatar(accountId: message.senderAccountId, avatar: services.people[message.senderAccountId]?.avatar ?? "robot-1", size: 34)
            }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cardShadow ? 22 : 18, style: .continuous)
                            .fill((message.isMine ? theme.bubbleMine : theme.bubbleTheirs).color)
                            .shadow(color: .black.opacity(theme.cardShadow ? 0.06 : 0), radius: 4, y: 2)
                    )
                    .foregroundStyle((message.isMine ? theme.onBubbleMine : theme.onBubbleTheirs).color)
                if message.status == .failed {
                    Button {
                        Task { await services.chat.retry(message) }
                    } label: {
                        Label("Not sent. Tap to try again.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(theme.danger.color)
                    }
                }
            }
            if !message.isMine {
                Spacer(minLength: 48)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.content.body {
        case let .text(text):
            Text(verbatim: text)
        case let .image(pointer):
            AttachmentImage(pointer: pointer, services: services)
        case let .voice(pointer):
            VoiceNoteView(pointer: pointer, services: services)
        case .call:
            CallMessageLabel(message: message)
        case let .video(pointer):
            VideoBubble(pointer: pointer, services: services)
        case let .document(pointer, name):
            DocumentBubble(pointer: pointer, name: name, services: services)
        case let .contact(card):
            ContactBubble(card: card)
        case let .location(place):
            LocationBubble(place: place)
        }
    }
}

/// A call in the chat, named by how it ended on this phone, as kept in the history.
struct CallMessageLabel: View {
    let message: ChatMessage

    var body: some View {
        let result = message.callResult
        Label {
            switch result?.kind {
            case .answered?:
                Text("Call answered - \(Duration.seconds(result?.seconds ?? 0).formatted(.time(pattern: .hourMinuteSecond)))")
            case .declined?:
                Text("Call declined")
            case .unanswered?:
                if result?.incoming == true {
                    Text("Missed call")
                } else {
                    Text("Call unanswered")
                }
            case nil:
                Text("Call")
            }
        } icon: {
            Image(systemName: result?.kind == .answered ? "phone.fill" : "phone.down.fill")
        }
    }
}

/// A video: tap to play it, decrypted on the phone.
struct VideoBubble: View {
    let pointer: AttachmentPointer
    let services: AppServices
    @State private var file: URL?
    @State private var playing = false

    var body: some View {
        Button {
            Task {
                if file == nil {
                    file = await decryptedFile(pointer, services: services, name: "\(pointer.id).mov")
                }
                playing = file != nil
            }
        } label: {
            Label { Text("Video") } icon: { Image(systemName: "play.rectangle.fill") }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $playing) {
            if let file {
                VideoPlayer(player: AVPlayer(url: file))
                    .ignoresSafeArea()
            }
        }
    }
}

/// A file: tap to decrypt it, then share or save it.
struct DocumentBubble: View {
    let pointer: AttachmentPointer
    let name: String
    let services: AppServices
    @State private var file: URL?

    var body: some View {
        if let file {
            ShareLink(item: file) {
                Label(name, systemImage: "doc.fill").lineLimit(2)
            }
        } else {
            Button {
                Task { file = await decryptedFile(pointer, services: services, name: "\(pointer.id)-\(name)") }
            } label: {
                Label(name, systemImage: "arrow.down.doc.fill").lineLimit(2)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A contact card: its name, and tappable numbers and emails.
struct ContactBubble: View {
    let card: ContactCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(verbatim: card.name) } icon: { Image(systemName: "person.crop.circle.fill") }
                .font(.headline)
            ForEach(card.phones, id: \.self) { phone in
                if let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                    Link(destination: url) { Text(verbatim: phone) }
                }
            }
            ForEach(card.emails, id: \.self) { email in
                if let url = URL(string: "mailto:" + email) {
                    Link(destination: url) { Text(verbatim: email) }
                }
            }
        }
    }
}

/// A location: opens it in Maps.
struct LocationBubble: View {
    let place: Location

    var body: some View {
        let lat = String(format: "%.5f", place.latitude)
        let lon = String(format: "%.5f", place.longitude)
        if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
            Link(destination: url) {
                Label { Text("Location") } icon: { Image(systemName: "mappin.and.ellipse") }
            }
        }
    }
}

/// Decrypts an attachment into a temporary file, for playing or sharing.
@MainActor
private func decryptedFile(_ pointer: AttachmentPointer, services: AppServices, name: String) async -> URL? {
    guard let data = try? await services.chat.attachmentData(pointer) else { return nil }
    let url = FileManager.default.temporaryDirectory.appending(path: name.replacingOccurrences(of: "/", with: "_"))
    do {
        try data.write(to: url, options: .atomic)
        return url
    } catch {
        return nil
    }
}

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
            if continuation != nil { manager.requestLocation() }
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
