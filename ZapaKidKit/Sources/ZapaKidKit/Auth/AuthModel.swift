import Foundation
import Observation

/// Where the parent is in the sign-in flow. The screens follow this.
public enum AuthState: Equatable, Sendable {
    case loading
    case needsAgreement
    case signedOut
    case signedIn(ParentProfile)
    /// The shared age range doesn't show 18+. Parents only; kids join by scanning a parent's QR code.
    case blockedMinor
    /// The person declined to share their age range; they can try again and share it.
    case ageDeclined
    /// A kid's phone, paired with a parent's QR code.
    case kid(KidSession)

    public var isKid: Bool {
        if case .kid = self {
            true
        } else {
            false
        }
    }
}

/// Parent sign-in: agreement on first launch, a server nonce, sign-in with Apple or Google, session in the
/// Keychain, logout.
@MainActor
@Observable
public final class AuthModel {
    public private(set) var state: AuthState = .loading
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    /// The nonce for the next sign-in, fetched when the sign-in screen shows.
    public private(set) var nonce: SignInNonceGrant?

    /// What to give Apple or Google as their nonce: SHA-256 of the server nonce.
    public var providerNonce: String? {
        nonce.map { SignInNonce(raw: $0.nonce).hashed }
    }

    private let api: AuthAPI
    private let store: SessionStore
    private let agreement: AgreementStore
    private let kidStore: KidSessionStore
    private let now: @Sendable () -> Date

    public init(
        api: AuthAPI, store: SessionStore, agreement: AgreementStore,
        kidStore: KidSessionStore = InMemoryKidSessionStore(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.store = store
        self.agreement = agreement
        self.kidStore = kidStore
        self.now = now
    }

    /// The parent session's token (for the families API), if signed in as a parent.
    public var parentToken: String? {
        guard case .signedIn = state else { return nil }
        return try? store.load()?.token
    }

    /// A kid's phone was paired: keep the kid session and open in kid mode.
    public func kidPaired(_ session: KidSession) {
        do {
            try kidStore.save(session)
            state = .kid(session)
        } catch {
            errorMessage = String(localized: "Couldn't keep you signed in on this phone. Try again.", bundle: .module)
        }
    }

    /// At launch: the agreement first, then the stored session (checked with the API when online).
    public func start() async {
        guard agreement.acceptedVersion == ParentalAgreement.currentVersion else {
            state = .needsAgreement
            return
        }
        guard let session = try? store.load() else {
            if let kid = try? kidStore.load(), kid.expiresAt > now() {
                state = .kid(kid)
            } else {
                state = .signedOut
            }
            return
        }
        guard session.expiresAt > now() else {
            try? store.clear()
            state = .signedOut
            return
        }
        state = .signedIn(session.parent)
        do {
            let parent = try await api.me(token: session.token)
            try? store.save(Session(token: session.token, expiresAt: session.expiresAt, parent: parent))
            state = .signedIn(parent)
        } catch AuthAPIError.unauthorized {
            try? store.clear()
            state = .signedOut
        } catch {
            // Offline or the API is down: keep the session, the next launch checks again.
        }
    }

    public func acceptAgreement() async {
        agreement.accept(version: ParentalAgreement.currentVersion)
        await start()
    }

    /// Gets a nonce unless the current one is still good for at least a minute.
    public func prepareNonce() async {
        if let nonce, nonce.expiresAt.timeIntervalSince(now()) > 60 {
            return
        }
        nonce = nil
        do {
            nonce = try await api.signInNonce()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// After Apple or Google returned an ID token for `providerNonce`. A parent whose age range doesn't show 18+, or
    /// who declined to share it, is stopped here, before anything is sent: no data about a minor reaches ZapaKid.
    public func signIn(provider: SignInProvider, idToken: String, ageRange: AgeRange, displayName: String?) async {
        errorMessage = nil
        if ageRange.isMinor {
            state = .blockedMinor
            return
        }
        if ageRange.availability == .declined {
            state = .ageDeclined
            return
        }
        isBusy = true
        defer { isBusy = false }
        // Keep the nonce the provider token was made for, unless it is gone or expired (then the API would refuse it).
        if nonce.map({ $0.expiresAt <= now() }) ?? true {
            await prepareNonce()
        }
        guard let nonce else { return }
        self.nonce = nil // each nonce works once, whatever the answer
        do {
            let request = SignInRequest(
                provider: provider, idToken: idToken, nonce: nonce.nonce, ageRange: ageRange, displayName: displayName
            )
            let session = try await api.signIn(request)
            do {
                try store.save(session)
            } catch {
                state = .signedOut
                errorMessage = String(
                    localized: "Couldn't keep you signed in on this phone. Try again.",
                    bundle: .module
                )
                await prepareNonce()
                return
            }
            state = .signedIn(session.parent)
        } catch AuthAPIError.minorNotAllowed {
            state = .blockedMinor
        } catch AuthAPIError.ageDeclined {
            state = .ageDeclined
        } catch {
            state = .signedOut
            let message = Self.message(for: error)
            await prepareNonce()
            errorMessage = message
        }
    }

    /// Shown when Apple or Google sign-in itself failed (not cancelled).
    public func signInFailed(_ message: String) {
        errorMessage = message
    }

    /// From the declined-age screen back to sign-in, with a fresh nonce.
    public func tryAgain() async {
        state = .signedOut
        errorMessage = nil
        await prepareNonce()
    }

    /// Signs out on this phone. The session is removed even when the API can't be reached.
    public func logout() async {
        let session = try? store.load()
        try? store.clear()
        try? kidStore.clear()
        state = .signedOut
        errorMessage = nil
        if let session {
            try? await api.logout(token: session.token)
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? AuthAPIError {
        case .network:
            String(localized: "Can't reach ZapaKid. Check your connection and try again.", bundle: .module)
        case let .rateLimited(retryAfter?):
            String(localized: "Too many sign-in attempts. Try again in \(retryAfter) seconds.", bundle: .module)
        case .rateLimited:
            String(localized: "Too many sign-in attempts. Try again in a few minutes.", bundle: .module)
        case .invalidNonce, .invalidToken:
            String(localized: "Sign-in took too long or was already used. Please sign in again.", bundle: .module)
        case .providerUnavailable:
            String(localized: "Apple or Google can't be reached right now. Try again later.", bundle: .module)
        case .attestationFailed:
            String(
                localized: "This copy of ZapaKid couldn't be verified. Install it from the App Store.",
                bundle: .module
            )
        default:
            String(localized: "Sign-in didn't work. Try again.", bundle: .module)
        }
    }
}
