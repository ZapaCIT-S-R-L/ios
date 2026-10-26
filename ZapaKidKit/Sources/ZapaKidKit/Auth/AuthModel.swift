import Foundation
import Observation

/// Where the parent is in the sign-in flow. The screens follow this.
public enum AuthState: Equatable, Sendable {
    case loading
    case needsAgreement
    case signedOut
    case signedIn(ParentProfile)
    /// Under 18: parents only. Kids join by scanning a parent's QR code.
    case blockedMinor
}

/// Parent sign-in: agreement on first launch, sign-in with Apple or Google, session in the Keychain, logout.
@MainActor
@Observable
public final class AuthModel {
    public private(set) var state: AuthState = .loading
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    private let api: AuthAPI
    private let store: SessionStore
    private let agreement: AgreementStore

    public init(api: AuthAPI, store: SessionStore, agreement: AgreementStore) {
        self.api = api
        self.store = store
        self.agreement = agreement
    }

    /// At launch: the agreement first, then the stored session (checked with the API when online).
    public func start() async {
        guard agreement.acceptedVersion == ParentalAgreement.currentVersion else {
            state = .needsAgreement
            return
        }
        guard let session = try? store.load() else {
            state = .signedOut
            return
        }
        state = .signedIn(session.parent)
        do {
            let parent = try await api.me(token: session.token)
            try? store.save(Session(token: session.token, parent: parent))
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

    /// After Apple or Google returned an ID token. A parent known to be under 18 is blocked here, before anything is
    /// sent, so no data about a minor reaches ZapaKid.
    public func signIn(provider: SignInProvider, idToken: String, nonce: String, ageRange: AgeRange?) async {
        errorMessage = nil
        if ageRange?.isMinor == true {
            state = .blockedMinor
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let request = SignInRequest(provider: provider, idToken: idToken, nonce: nonce, ageRange: ageRange)
            let session = try await api.signIn(request)
            do {
                try store.save(session)
            } catch {
                state = .signedOut
                errorMessage = String(localized: "Couldn't keep you signed in on this phone. Try again.")
                return
            }
            state = .signedIn(session.parent)
        } catch AuthAPIError.minor {
            state = .blockedMinor
        } catch {
            state = .signedOut
            errorMessage = Self.message(for: error)
        }
    }

    /// Shown when Apple or Google sign-in itself failed (not cancelled).
    public func signInFailed(_ message: String) {
        errorMessage = message
    }

    /// Signs out on this phone. The session is removed even when the API can't be reached.
    public func logout() async {
        let session = try? store.load()
        try? store.clear()
        state = .signedOut
        errorMessage = nil
        if let session {
            try? await api.logout(token: session.token)
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? AuthAPIError {
        case .network:
            String(localized: "Can't reach ZapaKid. Check your connection and try again.")
        default:
            String(localized: "Sign-in didn't work. Try again.")
        }
    }
}
