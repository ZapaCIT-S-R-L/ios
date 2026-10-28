import Foundation

public struct FamilyParent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String?

    public init(id: String, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }
}

/// A kid: a nickname, a robot avatar and a grade. No real name, birthday or photo on the server.
public struct Kid: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var nickname: String
    public var avatar: String
    /// -1 kindergarten, 0 preparatory class, 1–12 school grade, nil not set.
    public var grade: Int?

    public init(id: String, nickname: String, avatar: String, grade: Int? = nil) {
        self.id = id
        self.nickname = nickname
        self.avatar = avatar
        self.grade = grade
    }

    private enum CodingKeys: String, CodingKey {
        case id, nickname, avatar, grade
    }
}

public struct Family: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var parents: [FamilyParent]
    public var kids: [Kid]

    public init(id: String, name: String?, parents: [FamilyParent], kids: [Kid]) {
        self.id = id
        self.name = name
        self.parents = parents
        self.kids = kids
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, parents, kids
    }
}

/// A one-time code (co-parent invitation, 72 h; kid pairing, 5 min). Secret until used; never logged.
public struct CodeGrant: Codable, Equatable, Sendable {
    public var code: String
    public var expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct PairingGrant: Codable, Equatable, Sendable {
    public var code: String
    public var expiresAt: Date
    public var kid: Kid

    public init(code: String, expiresAt: Date, kid: Kid) {
        self.code = code
        self.expiresAt = expiresAt
        self.kid = kid
    }
}

/// The kid's phone after pairing: a kid session (`zkk_`, 365 days) and who the kid is. The parent's identity key
/// fingerprint from the QR is kept to check the parent's key once the key directory is there.
public struct KidSession: Codable, Equatable, Sendable {
    public var token: String
    public var expiresAt: Date
    public var kid: Kid
    public var familyId: String
    public var familyName: String?
    public var parentFingerprint: String?

    public init(
        token: String, expiresAt: Date, kid: Kid, familyId: String, familyName: String?,
        parentFingerprint: String? = nil
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.kid = kid
        self.familyId = familyId
        self.familyName = familyName
        self.parentFingerprint = parentFingerprint
    }
}

public enum FamiliesAPIError: Error, Equatable, Sendable {
    case unauthorized
    case notFound
    /// 410: the invitation or pairing code is unknown, expired or used.
    case codeInvalid
    case tooManyKids
    case alreadyInFamily
    /// 429: 5 invitations or pairing codes are still open.
    case tooManyOpenCodes
    case rateLimited(retryAfter: Int?)
    case attestationFailed
    case server(status: Int, code: String?)
    case network
    case invalidResponse
}
