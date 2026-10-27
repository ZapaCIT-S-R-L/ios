import Foundation
import Testing
@testable import ZapaKidKit

/// The app ships in Romanian, English and German (String Catalogs). scripts/strings.js checks every key is
/// translated; these check the built bundles really contain the languages.
struct LocalizationTests {
    func text(_ key: String, _ language: String, in bundle: Bundle) -> String? {
        guard let path = bundle.path(forResource: language, ofType: "lproj"), let lproj = Bundle(path: path) else {
            return nil
        }
        return lproj.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test(arguments: [
        ("ro", "Conectează-te cu Google"),
        ("de", "Mit Google anmelden"),
    ])
    func appIsTranslated(language: String, expected: String) {
        #expect(text("Sign in with Google", language, in: .main) == expected)
    }

    /// English is the source language: its text is the key itself, so Xcode writes no en.lproj table.
    @Test func englishIsTheSourceLanguage() {
        #expect(Bundle.main.developmentLocalization == "en")
        #expect(Bundle.main.localizations.contains("ro"))
        #expect(Bundle.main.localizations.contains("de"))
    }

    @Test(arguments: [
        ("ro", "Nu ne putem conecta la ZapaKid. Verifică conexiunea și încearcă din nou."),
        ("de", "ZapaKid ist nicht erreichbar. Prüfe deine Verbindung und versuche es noch einmal."),
    ])
    func zapaKidKitIsTranslated(language: String, expected: String) {
        let key = "Can't reach ZapaKid. Check your connection and try again."
        #expect(text(key, language, in: .module) == expected)
    }

    @Test func interpolatedSecondsAreTranslated() throws {
        let format = try #require(text("Too many sign-in attempts. Try again in %lld seconds.", "ro", in: .module))
        #expect(String(format: format, 30) ==
            "Prea multe încercări de conectare. Încearcă din nou peste 30 de secunde.")
    }
}
