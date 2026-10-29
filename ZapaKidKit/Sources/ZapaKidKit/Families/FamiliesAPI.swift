import Foundation

/// Families and kid pairing on the account API (`/v1/families*`, `/v1/pairing/redeem`), per openapi.yaml in
/// zapakid-api (tags Families and Kid pairing).
public protocol FamiliesAPI: Sendable {
    /// The caller's family, created on the first call (201) and returned on later ones (200).
    func createFamily(name: String?, token: String) async throws -> Family
    func myFamily(token: String) async throws -> Family?
    func inviteParent(familyId: String, token: String) async throws -> CodeGrant
    func join(code: String, token: String) async throws -> Family
    func addKid(familyId: String, nickname: String, avatar: String, grade: Int?, token: String) async throws -> Kid
    func createPairing(familyId: String, kidId: String, token: String) async throws -> PairingGrant
    /// Renames a kid and/or changes its robot (`PATCH /v1/families/{familyId}/kids/{kidId}`); nil keeps a field.
    func updateKid(familyId: String, kidId: String, nickname: String?, avatar: String?, token: String) async throws
        -> Kid
    /// Removes the kid with its account and phones (`DELETE`, 204).
    func removeKid(familyId: String, kidId: String, token: String) async throws
    /// The signed-in parent's display name (`PATCH /v1/me`); answers with the updated parent.
    func setDisplayName(_ name: String, token: String) async throws -> FamilyParent
    /// No session: the code is the credential.
    func redeemPairing(code: String) async throws -> KidSession
}

public struct HTTPFamiliesAPI: FamiliesAPI {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = URLSession(configuration: HTTPAuthAPI.secureConfiguration())) {
        self.baseURL = baseURL
        self.session = session
    }

    public static var staging: HTTPFamiliesAPI {
        // swiftlint:disable:next force_unwrapping
        HTTPFamiliesAPI(baseURL: URL(string: ZapaKidKit.apiBaseURL)!)
    }

    private struct Name: Encodable {
        var name: String?
    }

    private struct Code: Encodable {
        var code: String
    }

    private struct NewKid: Encodable {
        var nickname: String
        var avatar: String
        var grade: Int?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(nickname, forKey: .nickname)
            try container.encode(avatar, forKey: .avatar)
            try container.encode(grade, forKey: .grade) // null when not set
        }

        private enum CodingKeys: String, CodingKey {
            case nickname, avatar, grade
        }
    }

    /// Only the fields being changed are sent.
    private struct KidChange: Encodable {
        var nickname: String?
        var avatar: String?
    }

    private struct Families: Decodable {
        var families: [Family]
    }

    private struct Redeemed: Decodable {
        struct Token: Decodable {
            var token: String
            var expiresAt: Date
        }

        struct FamilyRef: Decodable {
            var id: String
            var name: String?
        }

        var session: Token
        var kid: Kid
        var family: FamilyRef
    }

    public func createFamily(name: String?, token: String) async throws -> Family {
        try await send("POST", ["v1", "families"], token: token, body: Name(name: name))
    }

    public func myFamily(token: String) async throws -> Family? {
        let reply: Families = try await send("GET", ["v1", "families"], token: token, body: Name?.none)
        return reply.families.first
    }

    public func inviteParent(familyId: String, token: String) async throws -> CodeGrant {
        try await send(
            "POST", ["v1", "families", familyId, "parents", "invitations"], token: token, body: Name?.none
        )
    }

    public func join(code: String, token: String) async throws -> Family {
        try await send("POST", ["v1", "families", "join"], token: token, body: Code(code: code))
    }

    public func addKid(
        familyId: String, nickname: String, avatar: String, grade: Int?, token: String
    ) async throws -> Kid {
        try await send(
            "POST", ["v1", "families", familyId, "kids"], token: token,
            body: NewKid(nickname: nickname, avatar: avatar, grade: grade)
        )
    }

    public func createPairing(familyId: String, kidId: String, token: String) async throws -> PairingGrant {
        try await send(
            "POST", ["v1", "families", familyId, "kids", kidId, "pairing"], token: token, body: Name?.none
        )
    }

    public func updateKid(
        familyId: String, kidId: String, nickname: String?, avatar: String?, token: String
    ) async throws -> Kid {
        try await send(
            "PATCH", ["v1", "families", familyId, "kids", kidId], token: token,
            body: KidChange(nickname: nickname, avatar: avatar)
        )
    }

    public func removeKid(familyId: String, kidId: String, token: String) async throws {
        _ = try await request("DELETE", ["v1", "families", familyId, "kids", kidId], token: token, body: Name?.none)
    }

    public func setDisplayName(_ name: String, token: String) async throws -> FamilyParent {
        try await send("PATCH", ["v1", "me"], token: token, body: DisplayName(displayName: name))
    }

    public func redeemPairing(code: String) async throws -> KidSession {
        let reply: Redeemed = try await send("POST", ["v1", "pairing", "redeem"], token: nil, body: Code(code: code))
        return KidSession(
            token: reply.session.token, expiresAt: reply.session.expiresAt, kid: reply.kid,
            familyId: reply.family.id, familyName: reply.family.name
        )
    }

    // MARK: HTTP

    private struct DisplayName: Encodable {
        var displayName: String
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable {
            var code: String?
        }

        var error: Detail?
    }

    private func url(_ segments: [String]) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segments.reduce(baseURL) { url, segment in
            url.appending(
                path: segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? "",
                directoryHint: .notDirectory
            )
        }
    }

    private func send<Reply: Decodable>(
        _ method: String, _ path: [String], token: String?, body: (some Encodable)?
    ) async throws -> Reply {
        let data = try await request(method, path, token: token, body: body)
        do {
            return try HTTPAuthAPI.decoder.decode(Reply.self, from: data)
        } catch {
            throw FamiliesAPIError.invalidResponse
        }
    }

    private func request(
        _ method: String, _ path: [String], token: String?, body: (some Encodable)?
    ) async throws -> Data {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FamiliesAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw FamiliesAPIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error?.code
            throw Self.error(
                status: http.statusCode,
                code: code,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return data
    }

    static func error(status: Int, code: String?, retryAfter: String?) -> FamiliesAPIError {
        switch (status, code) {
        case (401, _): .unauthorized
        case (403, "attestation_failed"): .attestationFailed
        case (404, _): .notFound
        case (409, "too_many_kids"): .tooManyKids
        case (409, "already_in_family"): .alreadyInFamily
        case (410, _): .codeInvalid
        case (429, "too_many_pairings"), (429, "too_many_invitations"): .tooManyOpenCodes
        case (429, _): .rateLimited(retryAfter: retryAfter.flatMap { Int($0) })
        default: .server(status: status, code: code)
        }
    }
}
