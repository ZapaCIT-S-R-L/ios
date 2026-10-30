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
        .navigationTitle(Text(verbatim: ""))
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
            isPresented: Binding(get: { problem != nil }, set: {
                if !$0 {
                    problem = nil
                }
            })
        ) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }
}

// MARK: Sending attachments and the composer

extension ChatView {
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
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
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
