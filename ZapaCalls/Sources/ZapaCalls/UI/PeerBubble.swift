import SwiftUI
import UIKit

/// The picture to show for a participant instead of their robot: the app sets this to the photo it keeps for them
/// (a contact's picture). Nil means the robot.
public enum CallPeerPhotos {
    @MainActor public static var photo: (String) -> UIImage? = { _ in nil }
}

/// A participant's robot (or photo) with the speaking ring (green, gently pulsing) and a muted badge.
struct PeerAvatar: View {
    let peer: CallPeer
    let size: CGFloat
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            face
                .padding(size * 0.06)
                .overlay {
                    Circle()
                        .strokeBorder(theme.speaking.color, lineWidth: max(4, size * 0.05))
                        .opacity(peer.isSpeaking ? 1 : 0)
                        .scaleEffect(peer.isSpeaking ? 1.04 : 0.96)
                        .animation(.easeInOut(duration: 0.25), value: peer.isSpeaking)
                }
            if peer.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: size * 0.16, weight: .bold))
                    .foregroundStyle(theme.onDanger.color)
                    .padding(size * 0.06)
                    .background(Circle().fill(theme.danger.color))
                    .accessibilityHidden(true)
            }
        }
    }
}

extension PeerAvatar {
    @MainActor @ViewBuilder var face: some View {
        if let photo = CallPeerPhotos.photo(peer.accountId) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            RobotAvatarView(avatar: peer.avatar, size: size)
        }
    }
}

/// One bubble in the group call grid.
struct PeerBubble: View {
    let peer: CallPeer
    @Environment(\.zapaTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 96

    var body: some View {
        VStack(spacing: 6) {
            PeerAvatar(peer: peer, size: min(size, 140))
            Text(verbatim: peer.displayName)
                .font(.headline)
                .foregroundStyle(theme.text.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: peer.displayName))
        .accessibilityValue(PeerBubble.state(of: peer))
        .accessibilityIdentifier("call.peer.\(peer.displayName)")
    }

    static func state(of peer: CallPeer) -> Text {
        if peer.isSpeaking {
            Text("speaking", bundle: .module)
        } else if peer.isMuted {
            Text("muted", bundle: .module)
        } else {
            Text(verbatim: "")
        }
    }
}
