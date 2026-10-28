import AVFoundation
import PhotosUI
import SwiftUI
import ZapaCalls
import ZapaChat

/// One chat: bubbles, a text field, photos, voice messages (hold the mic) and a big call button.
struct ChatView: View {
    let services: AppServices
    let conversation: Conversation
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var recorder = VoiceRecorder()
    @FocusState private var typing: Bool
    @Environment(\.zapaTheme) private var theme

    private var messages: [ChatMessage] {
        services.chat.messages[conversation.id] ?? []
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, services: services)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .background(theme.background.color.ignoresSafeArea())
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation { scroll.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(Text(verbatim: services.name(of: conversation)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = ImageScrubber.jpeg(data) {
                    await services.chat.send(
                        attachment: jpeg, kind: .image, mimeType: "image/jpeg", duration: nil, in: conversation.id
                    )
                }
                photo = nil
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $photo, matching: .images) {
                Image(systemName: "photo.fill")
                    .font(.title2)
                    .foregroundStyle(theme.accent.color)
                    .frame(width: theme.minTapTarget, height: theme.minTapTarget)
            }
            .accessibilityLabel(Text("Send a photo"))
            .accessibilityIdentifier("chat.photo")
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
                RobotAvatarView(avatar: services.people[message.senderAccountId]?.avatar ?? "robot-1", size: 34)
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
            Label { Text("Call") } icon: { Image(systemName: "phone.fill") }
        }
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
