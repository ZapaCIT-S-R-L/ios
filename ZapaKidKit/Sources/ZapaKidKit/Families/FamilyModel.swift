import Foundation
import Observation

/// The parent's family screen: the family (created on first open), adding kids, co-parent invitations and the
/// kid pairing QR.
@MainActor
@Observable
public final class FamilyModel {
    public private(set) var family: Family?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    private let api: FamiliesAPI
    private let token: () -> String?
    private let fingerprint: () -> String?

    /// `fingerprint`: this parent's identity key fingerprint (hex) for the pairing QR.
    public init(api: FamiliesAPI, token: @escaping () -> String?, fingerprint: @escaping () -> String?) {
        self.api = api
        self.token = token
        self.fingerprint = fingerprint
    }

    public func load() async {
        await run { api, token in
            family = try await api.createFamily(name: nil, token: token)
        }
    }

    /// Adds a kid; false when the nickname is empty or the API refused.
    public func addKid(nickname: String, avatar: String, grade: Int?) async -> Bool {
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty, nickname.count <= 40, let familyId = family?.id else { return false }
        var added = false
        await run { api, token in
            let kid = try await api.addKid(
                familyId: familyId, nickname: nickname, avatar: avatar, grade: grade, token: token
            )
            family?.kids.append(kid)
            added = true
        }
        return added
    }

    public struct Pairing: Equatable, Sendable {
        public let link: PairingLink
        public let expiresAt: Date
        public let kid: Kid
    }

    public func pairing(for kid: Kid) async -> Pairing? {
        guard let familyId = family?.id else { return nil }
        var pairing: Pairing?
        await run { api, token in
            let grant = try await api.createPairing(familyId: familyId, kidId: kid.id, token: token)
            pairing = Pairing(
                link: PairingLink(code: grant.code, fingerprint: fingerprint()), expiresAt: grant.expiresAt,
                kid: grant.kid
            )
        }
        return pairing
    }

    public struct Invitation: Equatable, Sendable {
        public let url: URL
        public let expiresAt: Date
    }

    public func inviteParent() async -> Invitation? {
        guard let familyId = family?.id else { return nil }
        var invitation: Invitation?
        await run { api, token in
            let grant = try await api.inviteParent(familyId: familyId, token: token)
            invitation = Invitation(url: InvitationLink.url(code: grant.code), expiresAt: grant.expiresAt)
        }
        return invitation
    }

    /// The second parent joins with a scanned or pasted invitation.
    public func join(_ text: String) async -> Bool {
        guard let code = InvitationLink.code(from: text) else {
            errorMessage = String(localized: "That isn't a ZapaKid invitation.", bundle: .module)
            return false
        }
        var joined = false
        await run { api, token in
            family = try await api.join(code: code, token: token)
            joined = true
        }
        return joined
    }

    private func run(_ work: (FamiliesAPI, String) async throws -> Void) async {
        guard let token = token() else { return }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await work(api, token)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        switch error as? FamiliesAPIError {
        case .network: String(localized: "Can't reach ZapaKid. Check your connection and try again.", bundle: .module)
        case .tooManyKids: String(localized: "A family can have up to 12 kids.", bundle: .module)
        case .tooManyOpenCodes: String(
                localized: "Too many open codes. Use one or wait until it expires.", bundle: .module
            )
        case .alreadyInFamily: String(
                localized: "You're already in a family with kids or another parent.", bundle: .module
            )
        case .codeInvalid: String(
                localized: "This code expired or was already used. Ask for a new one.", bundle: .module
            )
        default: String(localized: "Something went wrong. Try again.", bundle: .module)
        }
    }
}

/// The kid's phone: turns a scanned QR (or a typed code) into a kid session.
@MainActor
@Observable
public final class KidPairingModel {
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    private let api: FamiliesAPI
    private let auth: AuthModel

    public init(api: FamiliesAPI, auth: AuthModel) {
        self.api = api
        self.auth = auth
    }

    public func redeem(scanned text: String) async {
        errorMessage = nil
        guard let link = PairingLink(scanned: text) else {
            errorMessage = String(localized: "That isn't a ZapaKid pairing code.", bundle: .module)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            var session = try await api.redeemPairing(code: link.code)
            session.parentFingerprint = link.fingerprint
            auth.kidPaired(session)
        } catch {
            errorMessage = FamilyModel.message(for: error)
        }
    }
}
