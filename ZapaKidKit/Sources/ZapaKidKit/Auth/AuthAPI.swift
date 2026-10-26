import Foundation

/// Which account a parent signs in with. Parents only; kids join by scanning a parent's QR code.
public enum SignInProvider: String, Sendable, Codable, CaseIterable {
    case apple
    case google
}

/// What Apple's Declared Age Range said about the person signing in. `nil` bounds are open-ended.
/// The app asks with an age gate at 18, so an adult gets `lower: 18` and a minor gets `upper: 17` (or lower).
public struct AgeRange: Codable, Equatable, Sendable {
    public var lower: Int?
    public var upper: Int?
    /// The person chose not to share their age.
    public var declined: Bool

    public init(lower: Int?, upper: Int?, declined: Bool) {
        self.lower = lower
        self.upper = upper
        self.declined = declined
    }

    /// Known to be under 18. An unknown or declined age is not "minor": the API decides those.
    public var isMinor: Bool {
        guard let upper else { return false }
        return upper < 18
    }
}

/// The signed-in parent as the API returns it.
public struct ParentProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var email: String?

    public init(id: String, name: String?, email: String?) {
        self.id = id
        self.name = name
        self.email = email
    }
}

/// A session token for the API plus the parent it belongs to (cached so the app opens offline).
public struct Session: Codable, Equatable, Sendable {
    public var token: String
    public var parent: ParentProfile

    public init(token: String, parent: ParentProfile) {
        self.token = token
        self.parent = parent
    }
}

/// One sign-in attempt: the provider's ID token, the raw nonce whose SHA-256 the token carries, and the age range.
public struct SignInRequest: Equatable, Sendable {
    public var provider: SignInProvider
    public var idToken: String
    public var nonce: String
    public var ageRange: AgeRange?

    public init(provider: SignInProvider, idToken: String, nonce: String, ageRange: AgeRange?) {
        self.provider = provider
        self.idToken = idToken
        self.nonce = nonce
        self.ageRange = ageRange
    }
}

public enum AuthAPIError: Error, Equatable, Sendable {
    /// The session token is missing, expired or revoked.
    case unauthorized
    /// The API refused a parent under 18.
    case minor
    /// Any other error response from the API.
    case server(status: Int, code: String?)
    /// The response wasn't what the contract says.
    case invalidResponse
    /// No connection, timeout, TLS failure.
    case network
}

/// The parent sign-in part of the ZapaKid API. `HTTPAuthAPI` is the real one; tests and UI tests use fakes.
public protocol AuthAPI: Sendable {
    func signIn(_ request: SignInRequest) async throws -> Session
    func me(token: String) async throws -> ParentProfile
    func logout(token: String) async throws
}
