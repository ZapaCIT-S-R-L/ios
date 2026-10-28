import SwiftUI

/// The call: who (a big robot for 1:1, a bubble grid for groups), where the call is (calling…, ringing,
/// connecting, the call clock, reconnecting, ended) and big round buttons. VoiceOver, Dynamic Type and dark mode.
public struct CallScreen: View {
    let controller: CallController
    @Environment(\.zapaTheme) private var theme

    public init(controller: CallController) {
        self.controller = controller
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.cardShadow ? theme.secondary.color.opacity(0.25) : theme.background.color,
                    theme.background.color,
                ],
                startPoint: .top, endPoint: .bottom
            )
            .background(theme.background.color)
            .ignoresSafeArea()
            VStack(spacing: 24) {
                ScrollView {
                    VStack(spacing: 16) {
                        people
                        status
                    }
                    .padding(.top, 32)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                controls
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
        }
        .sensoryFeedback(trigger: controller.phase) { _, phase in
            switch phase {
            case .ringing: .impact(weight: .light)
            case .active: .success
            case .ended: .warning
            default: nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("call.screen")
    }

    // MARK: People

    @ViewBuilder private var people: some View {
        if controller.participants.count > 1 {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 20) {
                ForEach(controller.participants) { PeerBubble(peer: $0) }
            }
            .zapaCard(theme)
        } else if let peer = controller.participants.first {
            VStack(spacing: 12) {
                PeerAvatar(peer: peer, size: 160)
                    .phaseAnimator([1.0, 1.06]) { avatar, scale in
                        avatar.scaleEffect(isRinging ? scale : 1)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: peer.displayName))
                    .accessibilityValue(PeerBubble.state(of: peer))
                    .accessibilityIdentifier("call.peer.\(peer.displayName)")
                HStack(spacing: 8) {
                    Sparkles()
                    Text(verbatim: peer.displayName)
                        .font(.largeTitle.bold())
                        .foregroundStyle(theme.text.color)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("call.name")
                    Sparkles()
                }
            }
        }
    }

    private var isRinging: Bool {
        controller.phase == .ringing || controller.phase == .calling
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if controller.phase == .active, let start = controller.connectedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(verbatim: Duration.seconds(max(0, context.date.timeIntervalSince(start)).rounded(.down))
                    .formatted(.time(pattern: .minuteSecond)))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText.color)
                    .accessibilityIdentifier("call.timer")
            }
        } else {
            Text(statusKey, bundle: .module)
                .font(.title3.weight(.medium))
                .foregroundStyle(theme.secondaryText.color)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("call.status")
        }
    }

    private var statusKey: LocalizedStringKey {
        switch controller.phase {
        case .idle, .connecting: "Connecting…"
        case .calling: "Calling…"
        case .ringing: "Incoming call"
        case .active: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case let .ended(reason): Self.endedKey(reason, error: controller.lastError)
        }
    }

    static func endedKey(_ reason: CallEndReason, error: CallsAPIError?) -> LocalizedStringKey {
        switch reason {
        case .hungUp, .remoteEnded: "Call ended"
        case .declined: "Declined"
        case .missed: "Missed call"
        case .noAnswer: "No answer"
        case .failed: error == .callFull ? "The call is full (8 people)." : "The call was interrupted."
        }
    }

    // MARK: Buttons

    @ViewBuilder private var controls: some View {
        switch controller.phase {
        case .ringing:
            HStack(spacing: 56) {
                CallButton(systemImage: "phone.down.fill", title: "Decline", kind: .end) {
                    Task { await controller.decline() }
                }
                .accessibilityIdentifier("call.decline")
                CallButton(systemImage: "phone.fill", title: "Accept", kind: .accept) {
                    Task { await controller.accept() }
                }
                .accessibilityIdentifier("call.accept")
            }
        case .ended:
            EmptyView()
        default:
            HStack(spacing: 28) {
                CallButton(
                    systemImage: controller.isMuted ? "mic.slash.fill" : "mic.fill",
                    title: controller.isMuted ? "Unmute" : "Mute",
                    isOn: controller.isMuted
                ) {
                    Task { await controller.setMuted(!controller.isMuted) }
                }
                .accessibilityIdentifier("call.mute")
                CallButton(
                    systemImage: "speaker.wave.3.fill", title: "Speaker",
                    isOn: controller.isSpeakerOn,
                    accessibilityValue: controller.isSpeakerOn ? Text("On", bundle: .module) : Text(
                        "Off",
                        bundle: .module
                    )
                ) {
                    controller.setSpeakerOn(!controller.isSpeakerOn)
                }
                .accessibilityIdentifier("call.speaker")
                CallButton(systemImage: "phone.down.fill", title: "End call", kind: .end) {
                    Task { await controller.hangUp() }
                }
                .accessibilityIdentifier("call.end")
            }
        }
    }
}
