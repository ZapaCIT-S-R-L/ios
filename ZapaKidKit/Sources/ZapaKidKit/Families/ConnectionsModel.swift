import Foundation
import Observation

/// Another family this family is connected to (`/v1/connections`, per openapi.yaml).
public struct Connection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var family: ConnectedFamily
    public var sharedKids: SharedKids

    public init(id: String, createdAt: Date, family: ConnectedFamily, sharedKids: SharedKids) {
        self.id = id
        self.createdAt = createdAt
        self.family = family
        self.sharedKids = sharedKids
    }
}

public struct ConnectedFamily: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var parents: [ConnectedParent]

    public init(id: String, name: String?, parents: [ConnectedParent]) {
        self.id = id
        self.name = name
        self.parents = parents
    }
}

public struct ConnectedParent: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String?

    public init(id: String, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }
}

public struct SharedKids: Codable, Equatable, Sendable {
    /// Ids of your kids shared in this connection.
    public var mine: [String]
    /// The other family's kids shared with you: nickname and avatar only.
    public var theirs: [SharedKid]

    public init(mine: [String], theirs: [SharedKid]) {
        self.mine = mine
        self.theirs = theirs
    }
}

public struct SharedKid: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var nickname: String
    public var avatar: String

    public init(id: String, nickname: String, avatar: String) {
        self.id = id
        self.nickname = nickname
        self.avatar = avatar
    }
}

/// A one-time code another family's parent scans or opens (valid 72 hours, works once).
public struct ConnectionInvitation: Equatable, Sendable {
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    /// The link to share: `https://zapakid.ro/connect#<code>`.
    public var link: URL? {
        URL(string: "https://zapakid.ro/connect#\(code)")
    }
}

/// The connection calls on the account API.
public protocol ConnectionsAPI: Sendable {
    func list(token: String) async throws -> [Connection]
    func invite(token: String) async throws -> ConnectionInvitation
    func accept(code: String, token: String) async throws -> Connection
    func share(connectionId: String, kidId: String, token: String) async throws
    func unshare(connectionId: String, kidId: String, token: String) async throws
    func remove(connectionId: String, token: String) async throws
}

/// A connection code: `zkc_` and 43 URL-safe characters.
public enum ConnectionCode {
    /// The code from what was scanned or pasted: a bare code, or the link `https://zapakid.ro/connect#<code>`.
    public static func code(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.lastIndex(of: "#") else { return trimmed }
        return String(trimmed[trimmed.index(after: hash)...])
    }

    public static func isValid(_ code: String) -> Bool {
        let pattern = "^zkc_[A-Za-z0-9_-]{43}$"
        return code.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The parent's connected families: make a code, accept one, share or unshare their kids, remove a connection.
@MainActor
@Observable
public final class ConnectionsModel {
    public private(set) var connections: [Connection] = []
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    private let api: ConnectionsAPI
    private let token: () -> String?

    public init(api: ConnectionsAPI, token: @escaping () -> String?) {
        self.api = api
        self.token = token
    }

    public func load() async {
        await run { token in
            connections = try await api.list(token: token)
        }
    }

    /// A new code to show as a QR or share as a link; nil when it couldn't be made.
    public func invite() async -> ConnectionInvitation? {
        var made: ConnectionInvitation?
        await run { token in
            made = try await api.invite(token: token)
        }
        return made
    }

    /// Connects with the family whose code this is. False for a code that isn't one (nothing is sent).
    public func accept(code: String) async -> Bool {
        let code = ConnectionCode.code(from: code)
        guard ConnectionCode.isValid(code) else {
            errorMessage = String(localized: "That code isn't a ZapaKid connection code.", bundle: .module)
            return false
        }
        var accepted = false
        await run { token in
            connections.append(try await api.accept(code: code, token: token))
            accepted = true
        }
        return accepted
    }

    /// Shares (or unshares) one of your kids with a connected family.
    public func setShared(_ shared: Bool, kidId: String, in connectionId: String) async {
        await run { token in
            if shared {
                try await api.share(connectionId: connectionId, kidId: kidId, token: token)
            } else {
                try await api.unshare(connectionId: connectionId, kidId: kidId, token: token)
            }
            guard let index = connections.firstIndex(where: { $0.id == connectionId }) else { return }
            connections[index].sharedKids.mine.removeAll { $0 == kidId }
            if shared {
                connections[index].sharedKids.mine.append(kidId)
            }
        }
    }

    /// Disconnects the two families; the shared kids go with it.
    public func remove(_ connectionId: String) async {
        await run { token in
            try await api.remove(connectionId: connectionId, token: token)
            connections.removeAll { $0.id == connectionId }
        }
    }

    private func run(_ work: (String) async throws -> Void) async {
        guard let token = token() else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await work(token)
        } catch {
            errorMessage = FamilyModel.message(for: error)
        }
    }
}
