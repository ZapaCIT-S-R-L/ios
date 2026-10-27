import Foundation
import Testing

/// The built app declares its icon (AppIcon from Assets.xcassets).
struct AppIconTests {
    @Test func appDeclaresAppIcon() throws {
        let icons = try #require(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == "AppIcon")
    }
}
