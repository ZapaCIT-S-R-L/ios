import Foundation

/// Which account a parent signs in with. Parents only; kids join by scanning a parent's QR code.
public enum SignInProvider: String, Sendable, Codable, CaseIterable {
    case apple
    case google
}

/// What Apple's Declared Age Range said about the person signing in (`AgeRange` in openapi.yaml).
/// The app asks with an age gate at 18, so an adult gets `lowerBound: 18` and a minor `upperBound: 17` (or lower).
public struct AgeRange: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable {
        /// The person shared a range.
        case shared
        /// The person chose not to share it. The API refuses this (`403 age_declined`); they can try again.
        case declined
        /// The API isn't offered here (iOS before 26, region, account type). Allowed: the 18+ declaration in the
        /// parental agreement covers it.
        case unavailable
    }

    public var availability: Availability
    /// Always Apple's API on iOS, also when the parent signs in with Google.
    public var source = "apple_declared_age_range"
    public var lowerBound: Int?
    public var upperBound: Int?
    /// The platform's raw status, recorded as is (for example `sharing`, `declinedSharing`).
    public var platformStatus: String?

    public static func shared(lower: Int?, upper: Int?, platformStatus: String?) -> AgeRange {
        AgeRange(availability: .shared, lowerBound: lower, upperBound: upper, platformStatus: platformStatus)
    }

    public static func declined(platformStatus: String?) -> AgeRange {
        AgeRange(availability: .declined, lowerBound: nil, upperBound: nil, platformStatus: platformStatus)
    }

    public static let unavailable = AgeRange(availability: .unavailable, lowerBound: nil, upperBound: nil)

    /// A shared range that doesn't show 18+ (as the API decides: adult only when `lowerBound` ≥ 18).
    public var isMinor: Bool {
        availability == .shared && (lowerBound ?? 0) < 18
    }

    private enum CodingKeys: String, CodingKey {
        case availability, source, lowerBound, upperBound, platformStatus
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(availability, forKey: .availability)
        try container.encode(source, forKey: .source)
        try container.encode(lowerBound, forKey: .lowerBound) // required, null when open-ended
        try container.encode(upperBound, forKey: .upperBound)
        try container.encodeIfPresent(platformStatus, forKey: .platformStatus)
    }
}

/// The signed-in parent (`Parent` in openapi.yaml; the app keeps only what it shows).
public struct ParentProfile: Codable, Equatable, Sendable {
    public var id: String
    public var email: String?
    public var displayName: String?

    public init(id: String, email: String?, displayName: String?) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}

/// An API session (opaque token, never logged) plus the parent it belongs to, cached so the app opens offline.
public struct Session: Codable, Equatable, Sendable {
    public var token: String
    public var expiresAt: Date
    public var parent: ParentProfile

    public init(token: String, expiresAt: Date, parent: ParentProfile) {
        self.token = token
        self.expiresAt = expiresAt
        self.parent = parent
    }
}

/// A one-time sign-in nonce from `POST /v1/auth/nonce`: single use, valid for 10 minutes.
public struct SignInNonceGrant: Codable, Equatable, Sendable {
    public var nonce: String
    public var expiresAt: Date

    public init(nonce: String, expiresAt: Date) {
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

/// One sign-in attempt: the provider's ID token, the raw server nonce (the token carries its SHA-256), the age range.
public struct SignInRequest: Equatable, Sendable {
    public var provider: SignInProvider
    public var idToken: String
    public var nonce: String
    public var ageRange: AgeRange
    /// Apple gives the name only on the first sign-in; ignored for Google.
    public var displayName: String?

    public init(provider: SignInProvider, idToken: String, nonce: String, ageRange: AgeRange, displayName: String?) {
        self.provider = provider
        self.idToken = idToken
        self.nonce = nonce
        self.ageRange = ageRange
        self.displayName = displayName
    }
}

public enum AuthAPIError: Error, Equatable, Sendable {
    /// `401 unauthorized`: the session token is missing, expired or signed out.
    case unauthorized
    /// `401 invalid_token`: the Apple/Google token didn't verify.
    case invalidToken
    /// `401 invalid_nonce`: missing, wrong, expired or reused nonce. Get a new one and sign in again.
    case invalidNonce
    /// `403 minor_not_allowed`: the shared age range doesn't show 18+.
    case minorNotAllowed
    /// `403 age_declined`: the person declined to share their age range.
    case ageDeclined
    /// `403 attestation_failed`: not a genuine app on a genuine device (App Attest, required before launch).
    case attestationFailed
    /// `429 rate_limited`, with `Retry-After` in seconds when the API sent it.
    case rateLimited(retryAfter: Int?)
    /// `503 provider_unavailable`: Apple's or Google's keys couldn't be fetched.
    case providerUnavailable
    /// Any other error response.
    case server(status: Int, code: String?)
    /// The response wasn't what the contract says.
    case invalidResponse
    /// No connection, timeout, TLS failure.
    case network
}

/// The Sign-in and Account parts of the ZapaKid API. `HTTPAuthAPI` is the real one; tests and UI tests use fakes.
public protocol AuthAPI: Sendable {
    func signInNonce() async throws -> SignInNonceGrant
    func signIn(_ request: SignInRequest) async throws -> Session
    func me(token: String) async throws -> ParentProfile
    func logout(token: String) async throws
}
