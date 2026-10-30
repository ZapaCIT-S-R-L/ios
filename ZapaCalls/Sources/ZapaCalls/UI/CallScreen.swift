import SwiftUI

/// The call: who (a big robot for 1:1, a bubble grid for groups), where the call is (calling…, ringing,
/// connecting, the call clock, reconnecting, ended) and big round buttons. VoiceOver, Dynamic Type and dark mode.
public struct CallScreen: View {
    let controller: CallController
    /// The phone's calls: the buttons go through CallKit when there is one (else straight to the controller).
    let coordinator: CallCoordinator?
    @Environment(\.zapaTheme) private var theme

    public init(controller: CallController, coordinator: CallCoordinator? = nil) {
        self.controller = controller
        self.coordinator = coordinator
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
                if isOneToOne {
                    header
                }
                ScrollView {
                    VStack(spacing: 16) {
                        people
                        if !isOneToOne {
                            status
                        }
                    }
                    .padding(.top, isOneToOne ? 8 : 32)
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
            // The big picture in the middle; the name and the clock are in the header.
            PeerAvatar(peer: peer, size: 260)
                .phaseAnimator([1.0, 1.06]) { avatar, scale in
                    avatar.scaleEffect(isRinging ? scale : 1)
                } animation: { _ in .easeInOut(duration: 0.9) }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: peer.displayName))
                .accessibilityValue(PeerBubble.state(of: peer))
                .accessibilityIdentifier("call.peer.\(peer.displayName)")
        }
    }

    private var isOneToOne: Bool {
        controller.participants.count <= 1
    }

    /// One-to-one: "Calling <name>…" and the clock under it, which starts when they answer.
    private var header: some View {
        VStack(spacing: 6) {
            // While it rings, "Calling <name>…"; once they answer, just their name.
            Text(verbatim: titleText)
                .font(.largeTitle.bold())
                .foregroundStyle(theme.text.color)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("call.title")
            clock
        }
        .padding(.top, 24)
    }

    private var titleText: String {
        let name = controller.participants.first?.displayName ?? ""
        if controller.phase == .active {
            return name
        }
        if controller.isIncoming {
            return String(localized: "\(name) is calling…", bundle: .module)
        }
        return String(localized: "Calling \(name)…", bundle: .module)
    }

    /// 00:00:00 until the call is answered, then the time since then.
    @ViewBuilder private var clock: some View {
        if controller.phase == .active, let start = controller.connectedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(verbatim: Duration.seconds(max(0, context.date.timeIntervalSince(start)).rounded(.down))
                    .formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.largeTitle.monospacedDigit())
                    .foregroundStyle(theme.secondaryText.color)
                    .accessibilityIdentifier("call.timer")
            }
        } else {
            Text(verbatim: "00:00:00")
                .font(.largeTitle.monospacedDigit())
                .foregroundStyle(theme.secondaryText.color)
                .accessibilityIdentifier("call.timer")
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
                    .font(.largeTitle.monospacedDigit())
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

    private func accept() async {
        if let coordinator {
            await coordinator.accept()
        } else {
            await controller.accept()
        }
    }

    private func decline() async {
        if let coordinator {
            await coordinator.hangUp()
        } else {
            await controller.decline()
        }
    }

    private func hangUp() async {
        if let coordinator {
            await coordinator.hangUp()
        } else {
            await controller.hangUp()
        }
    }

    @ViewBuilder private var controls: some View {
        switch controller.phase {
        case .ringing:
            HStack(spacing: 56) {
                CallButton(systemImage: "phone.down.fill", title: "Decline", kind: .end) {
                    Task { await decline() }
                }
                .accessibilityIdentifier("call.decline")
                CallButton(systemImage: "phone.fill", title: "Accept", kind: .accept) {
                    Task { await accept() }
                }
                .accessibilityIdentifier("call.accept")
            }
        case .ended:
            EmptyView()
        default:
            HStack(spacing: 16) {
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
                // Video is not in this version: greyed out until it is.
                CallButton(systemImage: "video.fill", title: "Video") {}
                    .disabled(true)
                    .opacity(0.35)
                    .accessibilityIdentifier("call.video")
                CallButton(systemImage: "phone.down.fill", title: "End call", kind: .end) {
                    Task { await hangUp() }
                }
                .accessibilityIdentifier("call.end")
            }
        }
    }
}
