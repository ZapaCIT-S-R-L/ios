import SwiftUI

/// A big round call button (at least 76 pt) with its name under it; the icon never scales away, the name follows
/// Dynamic Type.
struct CallButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    let tint: Color
    var isOn = false
    var accessibilityValue: Text?
    let action: () -> Void

    @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 76
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: min(diameter, 110) * 0.38, weight: .semibold))
                    .foregroundStyle(isOn ? Color.black : Color.white)
                    .frame(width: min(diameter, 110), height: min(diameter, 110))
                    .background(Circle().fill(isOn ? Color.white : tint))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                Text(title, bundle: .module)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
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
