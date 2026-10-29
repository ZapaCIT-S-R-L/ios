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

    /// The signed-in parent's account id: only their own row can be renamed.
    public let me: String?
    private let api: FamiliesAPI
    private let token: () -> String?
    private let fingerprint: () -> String?

    /// `fingerprint`: this parent's identity key fingerprint (hex) for the pairing QR.
    public init(
        api: FamiliesAPI, me: String? = nil, token: @escaping () -> String?, fingerprint: @escaping () -> String?
    ) {
        self.api = api
        self.me = me
        self.token = token
        self.fingerprint = fingerprint
    }

    public func canRename(_ parent: FamilyParent) -> Bool {
        parent.id == me
    }

    /// Changes the signed-in parent's display name: trimmed, 1 to 40 characters, no control characters (as the API).
    public func rename(to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            errorMessage = String(localized: "Use 1 to 40 letters for your name.", bundle: .module)
            return false
        }
        var renamed = false
        await run { api, token in
            let parent = try await api.setDisplayName(name, token: token)
            if var updated = family {
                updated.parents = updated.parents.map { $0.id == parent.id ? parent : $0 }
                family = updated
            }
            renamed = true
        }
        return renamed
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

    /// Changes a kid's nickname and robot. False for an empty nickname or when the API refused.
    public func renameKid(_ kid: Kid, nickname: String, avatar: String) async -> Bool {
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty, nickname.count <= 40, let familyId = family?.id else { return false }
        var renamed = false
        await run { api, token in
            let updated = try await api.updateKid(
                familyId: familyId, kidId: kid.id, nickname: nickname, avatar: avatar, token: token
            )
            if let index = family?.kids.firstIndex(where: { $0.id == kid.id }) {
                family?.kids[index] = updated
            }
            renamed = true
        }
        return renamed
    }

    /// Removes a kid from the family, with their account and phones.
    public func removeKid(_ kid: Kid) async -> Bool {
        guard let familyId = family?.id else { return false }
        var removed = false
        await run { api, token in
            try await api.removeKid(familyId: familyId, kidId: kid.id, token: token)
            family?.kids.removeAll { $0.id == kid.id }
            removed = true
        }
        return removed
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
            session.pairedAt = Date()
            auth.kidPaired(session)
        } catch {
            errorMessage = FamilyModel.message(for: error)
        }
    }
}
