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
                    .background {
                        LiquidSurface(
                            tint: fill,
                            shape: RoundedRectangle(
                                cornerRadius: theme.roundCallButtons ? size / 2 : size * 0.3,
                                style: .continuous
                            )
                        )
                        .shadow(color: .black.opacity(theme.cardShadow ? 0.15 : 0), radius: 6, y: 3)
                    }
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

/// A glossy, liquid button surface: Liquid Glass on iOS 26, otherwise a tinted gradient with a light rim and a
/// highlight on top.
struct LiquidSurface<S: Shape>: View {
    let tint: Color
    let shape: S

    var body: some View {
        if #available(iOS 26, *) {
            Color.clear
                .glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            shape
                .fill(LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.72)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(alignment: .top) {
                    shape
                        .fill(LinearGradient(
                            colors: [.white.opacity(0.45), .white.opacity(0)],
                            startPoint: .top, endPoint: .center
                        ))
                        .padding(2)
                        .mask(shape)
                }
                .overlay {
                    shape.stroke(.white.opacity(0.35), lineWidth: 1)
                }
        }
    }
}
