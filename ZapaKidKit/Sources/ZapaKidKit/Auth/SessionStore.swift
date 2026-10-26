import Foundation
import Security

/// Where the API session is kept between launches.
public protocol SessionStore: Sendable {
    func load() throws -> Session?
    func save(_ session: Session) throws
    func clear() throws
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

/// The session in the Keychain: readable only while the phone is unlocked, only on this device, never synced to
/// iCloud and never in backups. Signing in on a new phone gets a new session (and never the chat keys).
public struct KeychainSessionStore: SessionStore {
    public let service: String
    private let account = "session"

    public init(service: String = "ro.zapakid.app.session") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() throws -> Session? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        try clear()
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// A session store in memory, for tests and UI tests.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?
    private var shouldFailSaves = false

    public init(session: Session? = nil) {
        self.session = session
    }

    /// Makes `save` throw, to test what happens when the Keychain refuses.
    public var failSaves: Bool {
        get { lock.withLock { shouldFailSaves } }
        set { lock.withLock { shouldFailSaves = newValue } }
    }

    public func load() throws -> Session? {
        lock.withLock { session }
    }

    public func save(_ session: Session) throws {
        try lock.withLock {
            if shouldFailSaves {
                throw KeychainError(status: errSecIO)
            }
            self.session = session
        }
    }

    public func clear() throws {
        lock.withLock { session = nil }
    }
}
