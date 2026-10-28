import SwiftUI
import Testing
@testable import ZapaCalls
@testable import ZapaKid
import ZapaKidKit

/// Two looks: "Calm & modern" for parents (mint and lavender on off-white) and "Playful & bright" for kids (warm
/// yellow and sky blue, rounded type). The session decides which; both pass WCAG AA for every text color pair.
struct ThemeTests {
    let kid = KidSession(
        token: "zkk", expiresAt: .distantFuture, kid: Kid(id: "k1", nickname: "Ana", avatar: "robot-4"),
        familyId: "f1", familyName: nil
    )

    @Test func theSessionRoleChoosesTheTheme() {
        #expect(AuthState.kid(kid).themeRole == .kid)
        #expect(AuthState.signedIn(ParentProfile(id: "p", email: nil, displayName: nil)).themeRole == .parent)
        #expect(AuthState.signedOut.themeRole == .parent, "sign-in is a parent screen")
    }

    @Test func kidsGetRoundedTypeBigCornersAndSparkles() {
        let kid = ZapaTheme.make(.kid, dark: false)
        let parent = ZapaTheme.make(.parent, dark: false)

        #expect(kid.fontDesign == .rounded)
        #expect(parent.fontDesign == .default)
        #expect(kid.cardRadius > parent.cardRadius)
        #expect(kid.sparkles)
        #expect(!parent.sparkles)
        #expect(kid.minTapTarget >= 60)
        #expect(parent.minTapTarget >= 44)
    }

    @Test(arguments: [ZapaTheme.Role.parent, .kid], [false, true])
    func everyTextColorPairMeetsWCAGAA(role: ZapaTheme.Role, dark: Bool) {
        let theme = ZapaTheme.make(role, dark: dark)

        for pair in theme.textPairs {
            #expect(pair.foreground.contrast(with: pair.background) >= 4.5, "\(role) dark=\(dark): \(pair.name)")
        }
        #expect(theme.textPairs.count >= 10)
    }

    @Test func contrastMatchesTheWCAGFormula() {
        #expect(abs(ThemeColor(0x000000).contrast(with: ThemeColor(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(ThemeColor(0x777777).contrast(with: ThemeColor(0xFFFFFF)) - 4.48) < 0.01)
    }
}
