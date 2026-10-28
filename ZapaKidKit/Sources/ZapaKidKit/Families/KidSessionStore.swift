import Foundation

/// Where the kid session lives on a kid's phone.
public protocol KidSessionStore: Sendable {
    func load() throws -> KidSession?
    func save(_ session: KidSession) throws
    func clear() throws
}

/// In the Keychain like the parent session (this device only, never synced, never in backups).
public struct KeychainKidSessionStore: KidSessionStore {
    private let inner: KeychainSessionStore

    public init(service: String = "ro.zapakid.app.kid-session") {
        inner = KeychainSessionStore(service: service)
    }

    public func load() throws -> KidSession? {
        try inner.loadData().flatMap { try? JSONDecoder().decode(KidSession.self, from: $0) }
    }

    public func save(_ session: KidSession) throws {
        try inner.saveData(JSONEncoder().encode(session))
    }

    public func clear() throws {
        try inner.clear()
    }
}

public final class InMemoryKidSessionStore: KidSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: KidSession?

    public init(session: KidSession? = nil) {
        self.session = session
    }

    public func load() throws -> KidSession? {
        lock.withLock { session }
    }

    public func save(_ session: KidSession) throws {
        lock.withLock { self.session = session }
    }

    public func clear() throws {
        lock.withLock { session = nil }
    }
}
