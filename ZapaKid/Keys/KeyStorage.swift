import Foundation
import Security

/// One generic-password item in the Keychain, readable only while the phone is unlocked.
/// By default this device only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synced, never in backups).
/// `synchronizable` is only for the account identity, the one item that goes to iCloud Keychain.
struct KeychainData {
    struct Failure: Error, Equatable {
        let status: OSStatus
    }

    let service: String
    let account: String
    var synchronizable = false

    /// The account's libsignal identity key pair: the one deliberately synchronizable item.
    static func syncedIdentity(service: String = "ro.zapakid.app.identity") -> KeychainData {
        KeychainData(service: service, account: "identity", synchronizable: true)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return data
    }

    func save(_ data: Data) throws {
        try clear()
        var item = query
        item[kSecValueData as String] = data
        // A synced item can't be "this device only"; it is still readable only while unlocked.
        item[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Files that only this phone can read while it is unlocked: Data Protection class Complete, written atomically,
/// excluded from iCloud and Finder backups. For libsignal records (private prekeys, sessions, peer identities).
struct ProtectedFileStore {
    /// Atomic, and readable only while the phone is unlocked.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    let directory: URL

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// The app's key directory: Application Support/Keys.
    static func appKeys() throws -> ProtectedFileStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try ProtectedFileStore(directory: base.appendingPathComponent("Keys", isDirectory: true))
    }

    func read(_ name: String) throws -> Data? {
        let url = file(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to name: String) throws {
        var url = file(name)
        try data.write(to: url, options: Self.writeOptions)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func delete(_ name: String) throws {
        let url = file(name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func file(_ name: String) -> URL {
        precondition(name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }, "plain file names only")
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
