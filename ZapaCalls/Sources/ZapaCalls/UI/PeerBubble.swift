import SwiftUI

/// A participant's robot with the speaking ring (green, gently pulsing) and a muted badge.
struct PeerAvatar: View {
    let peer: CallPeer
    let size: CGFloat
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RobotAvatarView(avatar: peer.avatar, size: size)
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
