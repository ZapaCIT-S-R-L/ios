import SwiftUI
import ZapaCalls
import ZapaChat

/// The end-to-end encryption note, in a small bubble above the tab bar.
struct E2EEBadge: View {
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        Label { Text("End-to-end encrypted") } icon: { Image(systemName: "lock.fill") }
            .font(.caption)
            .foregroundStyle(.gray)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.15)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("theme.e2ee")
            .accessibilityValue(Text(verbatim: theme.role.rawValue))
            .padding(.bottom, 4)
    }
}

/// The ZapaKid logo for the top left of a screen.
struct ZapaLogo: View {
    var body: some View {
        Image("ZapaLogo")
            .resizable()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityLabel(Text("ZapaKid"))
    }
}

/// The top bar every main screen shares: the logo top left, the title centered, inline.
struct ZapaTopBar: ViewModifier {
    let title: LocalizedStringKey
    var onTitleTap: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        ZapaLogo()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        ZapaLogo()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.title2.bold())
                        .contentShape(Rectangle())
                        .onTapGesture { onTitleTap?() }
                        .accessibilityHidden(true)
                }
            }
    }
}
