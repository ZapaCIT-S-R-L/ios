import SwiftUI

/// A big call button with its name under it: round for kids, a soft rounded square for parents (at least 76 pt);
/// the icon never scales away, the name follows Dynamic Type. Colors come from the theme.
struct CallButton: View {
    enum Kind {
        case normal
        case accept
        case end
    }

    let systemImage: String
    let title: LocalizedStringKey
    var kind: Kind = .normal
    var isOn = false
    var accessibilityValue: Text?
    let action: () -> Void

    @Environment(\.zapaTheme) private var theme
    @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 80
    @State private var taps = 0

    private var fill: Color {
        switch kind {
        case .end: theme.danger.color
        case .accept: Color(red: 0.13, green: 0.55, blue: 0.29)
        case .normal: (isOn ? theme.primary : theme.callButton).color
        }
    }

    private var iconColor: Color {
        switch kind {
        case .end: theme.onDanger.color
        case .accept: .white
        case .normal: (isOn ? theme.onPrimary : theme.onCallButton).color
        }
    }

    var body: some View {
        let size = min(diameter, 112)
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(
                            cornerRadius: theme.roundCallButtons ? size / 2 : size * 0.3,
                            style: .continuous
                        )
                        .fill(fill)
                        .shadow(color: .black.opacity(theme.cardShadow ? 0.15 : 0), radius: 6, y: 3)
                    )
                Text(title, bundle: .module)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.text.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title, bundle: .module))
        .accessibilityValue(accessibilityValue ?? Text(verbatim: ""))
        .accessibilityAddTraits(.isButton)
    }
}
