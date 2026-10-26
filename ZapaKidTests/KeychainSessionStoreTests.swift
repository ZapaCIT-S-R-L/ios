import Foundation
import Security
import Testing
@testable import ZapaKidKit

/// The session lives in the Keychain only: this device, while unlocked, never synced to iCloud.
@Suite(.serialized)
struct KeychainSessionStoreTests {
    let store = KeychainSessionStore(service: "ro.zapakid.app.tests.\(UUID().uuidString)")
    let session = Session(
        token: "zks_1",
        expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
        parent: ParentProfile(id: "p_1", email: nil, displayName: "TEST Parent")
    )

    @Test func savesAndLoadsTheSession() throws {
        defer { try? store.clear() }
        #expect(try store.load() == nil)

        try store.save(session)

        #expect(try store.load() == session)
    }

    @Test func saveReplacesTheOldSession() throws {
        defer { try? store.clear() }
        try store.save(session)
        let newer = Session(token: "zks_2", expiresAt: session.expiresAt, parent: session.parent)

        try store.save(newer)

        #expect(try store.load() == newer)
    }

    @Test func clearRemovesTheSession() throws {
        try store.save(session)

        try store.clear()

        #expect(try store.load() == nil)
        try store.clear() // clearing twice is fine
    }

    @Test func itemIsThisDeviceOnlyWhenUnlockedAndNotSynced() throws {
        defer { try? store.clear() }
        try store.save(session)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let items = try #require(result as? [[String: Any]])
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
    }
}
