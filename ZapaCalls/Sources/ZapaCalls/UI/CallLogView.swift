import SwiftUI

/// The call log: who, when, how it went, and a big call-back button.
public struct CallLogView: View {
    let entries: [CallLogEntry]
    let onCall: (CallLogEntry) -> Void
    @Environment(\.zapaTheme) private var theme

    public init(entries: [CallLogEntry], onCall: @escaping (CallLogEntry) -> Void) {
        self.entries = entries
        self.onCall = onCall
    }

    public var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Text("No calls yet", bundle: .module)
                } description: {
                    Text("Calls with your family show up here.", bundle: .module)
                }
            } else {
                List(entries) { entry in
                    row(entry)
                        .listRowBackground(theme.background.color)
                        .listRowSeparatorTint(theme.separator.color)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.background.color.ignoresSafeArea())
        .navigationTitle(Text("Calls", bundle: .module))
        .accessibilityIdentifier("calls.log")
    }

    private func row(_ entry: CallLogEntry) -> some View {
        let name = entry.peers.map(\.displayName).joined(separator: ", ")
        return HStack(spacing: 12) {
            RobotAvatarView(avatar: entry.peers.first?.avatar ?? "robot-1", size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name)
                    .font(.headline)
                    .foregroundStyle(entry.isMissed ? theme.danger.color : theme.text.color)
                HStack(spacing: 6) {
                    Image(systemName: icon(entry))
                        .foregroundStyle(entry.isMissed ? theme.danger.color : theme.secondaryText.color)
                        .accessibilityHidden(true)
                    Text(outcomeKey(entry), bundle: .module)
                    if entry.outcome == .answered {
                        Text(verbatim: Duration.seconds(entry.duration.rounded())
                            .formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText.color)
                Text(entry.startedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText.color)
            }
            Spacer(minLength: 8)
            Button {
                onCall(entry)
            } label: {
                Image(systemName: "phone.fill")
                    .font(.title3)
                    .foregroundStyle(theme.onPrimary.color)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(theme.primary.color))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Call back", bundle: .module))
            .accessibilityIdentifier("calls.log.callBack.\(entry.peers.first?.displayName ?? "")")
        }
        .padding(.vertical, 6)
    }

    private func icon(_ entry: CallLogEntry) -> String {
        switch (entry.direction, entry.outcome) {
        case (_, .missed): "phone.arrow.down.left.fill"
        case (.incoming, _): "phone.arrow.down.left"
        case (.outgoing, _): "phone.arrow.up.right"
        }
    }

    private func outcomeKey(_ entry: CallLogEntry) -> LocalizedStringKey {
        switch entry.outcome {
        case .answered: entry.direction == .incoming ? "Incoming call" : "Outgoing call"
        case .missed: "Missed call"
        case .declined: "Declined"
        case .noAnswer: "No answer"
        case .cancelled: "Cancelled"
        case .failed: "The call was interrupted."
        }
    }
}
