import SwiftUI

/// An sRGB color with the WCAG 2.x contrast math, so the palettes can be checked in tests.
public struct ThemeColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio, 1...21. Body text needs 4.5 (AA).
    public func contrast(with other: ThemeColor) -> Double {
        let (light, dark) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (light + 0.05) / (dark + 0.05)
    }
}

/// The app's two looks, chosen by who is signed in:
/// - parents: "Calm & modern": mint and lavender on off-white, thin lines, SF Pro, lots of whitespace;
/// - kids: "Playful & bright": warm yellow and sky blue, chunky rounded cards, SF Pro Rounded, sparkles, big targets.
/// Each in light and dark mode. Screens read it from the environment (`@Environment(\.zapaTheme)`).
public struct ZapaTheme: Sendable {
    public enum Role: String, Sendable {
        case parent
        case kid
    }

    public let role: Role
    // Surfaces
    public let background: ThemeColor
    public let surface: ThemeColor
    public let separator: ThemeColor
    // Text
    public let text: ThemeColor
    public let secondaryText: ThemeColor
    /// Links, icons and tinted text on the background.
    public let accent: ThemeColor
    // Fills with their text/icon color
    public let primary: ThemeColor
    public let onPrimary: ThemeColor
    public let secondary: ThemeColor
    public let onSecondary: ThemeColor
    public let bubbleMine: ThemeColor
    public let onBubbleMine: ThemeColor
    public let bubbleTheirs: ThemeColor
    public let onBubbleTheirs: ThemeColor
    public let callButton: ThemeColor
    public let onCallButton: ThemeColor
    public let danger: ThemeColor
    public let onDanger: ThemeColor
    public let speaking: ThemeColor
    /// Card tints, cycled per row (kids).
    public let cardTints: [ThemeColor]
    // Shape and type
    public let fontDesign: Font.Design
    public let cardRadius: CGFloat
    public let spacing: CGFloat
    public let minTapTarget: CGFloat
    /// Round (kids) or rounded-square (parents) call buttons.
    public let roundCallButtons: Bool
    public let cardShadow: Bool
    public let sparkles: Bool

    public struct TextPair: Sendable {
        public let name: String
        public let foreground: ThemeColor
        public let background: ThemeColor
    }

    /// Text color / background pairs the screens use; every one must reach WCAG AA (4.5).
    public var textPairs: [TextPair] {
        func pair(_ name: String, _ foreground: ThemeColor, _ background: ThemeColor) -> TextPair {
            TextPair(name: name, foreground: foreground, background: background)
        }
        return [
            pair("text/background", text, background), pair("secondary/background", secondaryText, background),
            pair("text/surface", text, surface), pair("secondary/surface", secondaryText, surface),
            pair("accent/background", accent, background), pair("accent/surface", accent, surface),
            pair("onPrimary/primary", onPrimary, primary), pair("onSecondary/secondary", onSecondary, secondary),
            pair("bubble mine", onBubbleMine, bubbleMine), pair("bubble theirs", onBubbleTheirs, bubbleTheirs),
            pair("call button", onCallButton, callButton), pair("danger", onDanger, danger),
        ] + cardTints.map { pair("text/card tint", text, $0) }
    }

    public static func make(_ role: Role, dark: Bool) -> ZapaTheme {
        switch (role, dark) {
        case (.parent, false): parentLight
        case (.parent, true): parentDark
        case (.kid, false): kidLight
        case (.kid, true): kidDark
        }
    }

    // MARK: Palettes

    static let parentLight = ZapaTheme(
        role: .parent, background: ThemeColor(0xF7F6F2), surface: ThemeColor(0xFFFFFF),
        separator: ThemeColor(0xE4E2DC), text: ThemeColor(0x1F2A2E), secondaryText: ThemeColor(0x5C6670),
        accent: ThemeColor(0x1F7A62), primary: ThemeColor(0x9EE3C9), onPrimary: ThemeColor(0x14302A),
        secondary: ThemeColor(0xDCD2F5), onSecondary: ThemeColor(0x3A2A6B), bubbleMine: ThemeColor(0xCDEFE2),
        onBubbleMine: ThemeColor(0x1F2A2E), bubbleTheirs: ThemeColor(0xECE6FA), onBubbleTheirs: ThemeColor(0x1F2A2E),
        callButton: ThemeColor(0x9EE3C9), onCallButton: ThemeColor(0x14302A), danger: ThemeColor(0xC93A3A),
        onDanger: ThemeColor(0xFFFFFF), speaking: ThemeColor(0x3FB58F), cardTints: [ThemeColor(0xFFFFFF)],
        fontDesign: .default, cardRadius: 14, spacing: 16, minTapTarget: 44, roundCallButtons: false,
        cardShadow: false, sparkles: false
    )

    static let parentDark = ZapaTheme(
        role: .parent, background: ThemeColor(0x121416), surface: ThemeColor(0x1C1F22),
        separator: ThemeColor(0x2C3034), text: ThemeColor(0xECEFF1), secondaryText: ThemeColor(0xA7B0B8),
        accent: ThemeColor(0x7FD8B8), primary: ThemeColor(0x7FD8B8), onPrimary: ThemeColor(0x0E1F19),
        secondary: ThemeColor(0x3B3360), onSecondary: ThemeColor(0xE6DEFF), bubbleMine: ThemeColor(0x1F3D33),
        onBubbleMine: ThemeColor(0xECEFF1), bubbleTheirs: ThemeColor(0x2A2540), onBubbleTheirs: ThemeColor(0xECEFF1),
        callButton: ThemeColor(0x7FD8B8), onCallButton: ThemeColor(0x0E1F19), danger: ThemeColor(0xB83232),
        onDanger: ThemeColor(0xFFFFFF), speaking: ThemeColor(0x7FD8B8), cardTints: [ThemeColor(0x1C1F22)],
        fontDesign: .default, cardRadius: 14, spacing: 16, minTapTarget: 44, roundCallButtons: false,
        cardShadow: false, sparkles: false
    )

    static let kidLight = ZapaTheme(
        role: .kid, background: ThemeColor(0xFFFBEA), surface: ThemeColor(0xFFFFFF),
        separator: ThemeColor(0xF2E3A6), text: ThemeColor(0x2B2B2B), secondaryText: ThemeColor(0x5A5A5A),
        accent: ThemeColor(0x1A6FAA), primary: ThemeColor(0xFFD54A), onPrimary: ThemeColor(0x3A2E00),
        secondary: ThemeColor(0x4FB3F0), onSecondary: ThemeColor(0x0B2A40), bubbleMine: ThemeColor(0xCDEBFF),
        onBubbleMine: ThemeColor(0x13324A), bubbleTheirs: ThemeColor(0xFFF1B8), onBubbleTheirs: ThemeColor(0x3A2E00),
        callButton: ThemeColor(0x1A6FAA), onCallButton: ThemeColor(0xFFFFFF), danger: ThemeColor(0xC93A3A),
        onDanger: ThemeColor(0xFFFFFF), speaking: ThemeColor(0xF5B700),
        cardTints: [ThemeColor(0xFFF4CF), ThemeColor(0xE1F2FF), ThemeColor(0xE3F6E3), ThemeColor(0xFFFFFF)],
        fontDesign: .rounded, cardRadius: 24, spacing: 14, minTapTarget: 64, roundCallButtons: true,
        cardShadow: true, sparkles: true
    )

    static let kidDark = ZapaTheme(
        role: .kid, background: ThemeColor(0x1A1A2E), surface: ThemeColor(0x24243A),
        separator: ThemeColor(0x3A3A55), text: ThemeColor(0xF5F5F5), secondaryText: ThemeColor(0xB9B9C9),
        accent: ThemeColor(0x8CCBFF), primary: ThemeColor(0xFFD54A), onPrimary: ThemeColor(0x3A2E00),
        secondary: ThemeColor(0x4FB3F0), onSecondary: ThemeColor(0x0B2A40), bubbleMine: ThemeColor(0x1D3B57),
        onBubbleMine: ThemeColor(0xF5F5F5), bubbleTheirs: ThemeColor(0x4A3F12), onBubbleTheirs: ThemeColor(0xF5F5F5),
        callButton: ThemeColor(0x1A6FAA), onCallButton: ThemeColor(0xFFFFFF), danger: ThemeColor(0xB83232),
        onDanger: ThemeColor(0xFFFFFF), speaking: ThemeColor(0xFFD54A),
        cardTints: [ThemeColor(0x33304A), ThemeColor(0x23344D), ThemeColor(0x24402F), ThemeColor(0x24243A)],
        fontDesign: .rounded, cardRadius: 24, spacing: 14, minTapTarget: 64, roundCallButtons: true,
        cardShadow: true, sparkles: true
    )
}

public extension EnvironmentValues {
    @Entry var zapaTheme: ZapaTheme = .parentLight
}

/// Puts the role's theme (light or dark, following the system) into the environment, with its font design and tint.
private struct ZapaThemeModifier: ViewModifier {
    let role: ZapaTheme.Role
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = ZapaTheme.make(role, dark: colorScheme == .dark)
        content
            .environment(\.zapaTheme, theme)
            .fontDesign(theme.fontDesign)
            .tint(theme.accent.color)
    }
}

public extension View {
    func zapaTheme(_ role: ZapaTheme.Role) -> some View {
        modifier(ZapaThemeModifier(role: role))
    }

    /// A card: the surface (or a tint), the theme's corner radius, a thin line (parents) or a soft shadow (kids).
    func zapaCard(_ theme: ZapaTheme, tint: ThemeColor? = nil) -> some View {
        padding(theme.spacing)
            .background(
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .fill((tint ?? theme.surface).color)
                    .shadow(color: .black.opacity(theme.cardShadow ? 0.08 : 0), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .strokeBorder(theme.separator.color, lineWidth: theme.cardShadow ? 2 : 0.5)
            )
    }
}

/// Small sparkles around a title (kids only); decorative, hidden from VoiceOver.
public struct Sparkles: View {
    @Environment(\.zapaTheme) private var theme

    public init() {}

    public var body: some View {
        if theme.sparkles {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.caption)
                Image(systemName: "sparkles").font(.footnote)
            }
            .foregroundStyle(theme.primary.color)
            .accessibilityHidden(true)
        }
    }
}
