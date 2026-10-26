import SwiftUI
import ZapaKidKit

@main
struct ZapaKidApp: App {
    var body: some Scene {
        WindowGroup {
            Text("ZapaKid")
                .font(.largeTitle)
                .accessibilityIdentifier("app.title")
        }
    }
}
