import Foundation
import Security

/// Where the API session is kept between launches.
public protocol SessionStore: Sendable {
    func load() throws -> Session?
    func save(_ session: Session) throws
    func clear() throws
}

/// The session in the Keychain (`KeychainItem`: this device only, while unlocked, never synced or backed up).
/// Signing in on a new phone gets a new session (and never the chat keys).
public struct KeychainSessionStore: SessionStore {
    private let item: KeychainItem

    public var service: String {
        item.service
    }

    public init(service: String = "ro.zapakid.app.session") {
        item = KeychainItem(service: service, account: "session")
    }

    public func load() throws -> Session? {
        try item.load().flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    public func save(_ session: Session) throws {
        try item.save(JSONEncoder().encode(session))
    }

    public func clear() throws {
        try item.clear()
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
