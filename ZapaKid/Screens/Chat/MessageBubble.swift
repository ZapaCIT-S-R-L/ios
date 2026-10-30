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
                PersonAvatar(
                    accountId: message.senderAccountId,
                    avatar: services.people[message.senderAccountId]?.avatar ?? "robot-1",
                    size: 34
                )
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
                let durationText = Duration.seconds(result?.seconds ?? 0).formatted(.time(pattern: .hourMinuteSecond))
                Text("Call answered - \(durationText)")
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
