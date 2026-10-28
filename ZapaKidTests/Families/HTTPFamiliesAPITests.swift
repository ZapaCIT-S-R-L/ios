import Foundation
import Testing
@testable import ZapaKidKit

/// The Families and Kid pairing client against a mocked account API, per the draft openapi.yaml in zapakid-api
/// (tags Families and Kid pairing).
@Suite(.serialized)
struct HTTPFamiliesAPITests {
    let host = "families.test.invalid"
    let familyJSON = """
    {"id":"f1","name":"Popescu","createdAt":"2026-10-27T18:00:00Z",\
    "parents":[{"id":"p1","displayName":"Mama"}],\
    "kids":[{"id":"k1","nickname":"Ana","avatar":"robot-4","grade":2,"createdAt":"2026-10-27T18:00:00.5Z"}]}
    """

    func api(_ handler: @escaping MockURLProtocol.Handler) -> HTTPFamiliesAPI {
        HTTPFamiliesAPI(
            baseURL: URL(string: "https://\(host)") ?? URL(filePath: "/"),
            session: MockURLProtocol.session(host: host, handler)
        )
    }

    var sent: [(request: URLRequest, body: Data?)] {
        MockURLProtocol.requests(host: host)
    }

    @Test func createFamilyReturnsTheFamilyWithParentsAndKids() async throws {
        let client = api { [familyJSON] _, _ in MockReply(201, familyJSON) }

        let family = try await client.createFamily(name: "Popescu", token: "zks_t")

        #expect(family.id == "f1")
        #expect(family.parents.first?.displayName == "Mama")
        #expect(family.kids.first == Kid(id: "k1", nickname: "Ana", avatar: "robot-4", grade: 2))
        #expect(sent.first?.request.url?.path == "/v1/families")
        #expect(sent.first?.request.httpMethod == "POST")
        #expect(sent.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_t")
        #expect(sent.first?.body?.json?["name"] as? String == "Popescu")
    }

    @Test func setDisplayNamePatchesMe() async throws {
        let client = api { _, _ in
            MockReply(
                200,
                #"{"id":"p1","email":null,"displayName":"Tata","ageRange":null,"createdAt":"2026-10-27T18:00:00Z"}"#
            )
        }

        let parent = try await client.setDisplayName("Tata", token: "zks_t")

        #expect(parent == FamilyParent(id: "p1", displayName: "Tata"))
        #expect(sent.first?.request.url?.path == "/v1/me")
        #expect(sent.first?.request.httpMethod == "PATCH")
        #expect(sent.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_t")
        #expect(sent.first?.body?.json?["displayName"] as? String == "Tata")
    }

    @Test func listFamiliesReturnsTheOneFamily() async throws {
        let client = api { [familyJSON] _, _ in MockReply(200, #"{"families":[\#(familyJSON)]}"#) }

        let family = try await client.myFamily(token: "zks_t")

        #expect(family?.name == "Popescu")
        #expect(sent.first?.request.httpMethod == "GET")
    }

    @Test func addKidSendsOnlyNicknameAvatarAndGrade() async throws {
        let client = api { _, _ in
            MockReply(
                201,
                #"{"id":"k2","nickname":"Ion","avatar":"robot-7","grade":-1,"createdAt":"2026-10-27T18:00:00Z"}"#
            )
        }

        let kid = try await client.addKid(familyId: "f1", nickname: "Ion", avatar: "robot-7", grade: -1, token: "t")

        #expect(kid.grade == -1)
        #expect(sent.first?.request.url?.path == "/v1/families/f1/kids")
        let body = try #require(sent.first?.body?.json)
        #expect(Set(body.keys) == ["nickname", "avatar", "grade"])
    }

    @Test func invitationsPairingJoinAndRedeem() async throws {
        let code = "zki_" + String(repeating: "a", count: 43)
        let pairing = "zkp_" + String(repeating: "b", count: 43)
        let kidToken = "zkk_" + String(repeating: "c", count: 43)
        let client = api { [familyJSON] request, _ in
            switch request.url?.path {
            case "/v1/families/f1/parents/invitations":
                MockReply(201, #"{"code":"\#(code)","expiresAt":"2026-10-30T18:00:00Z"}"#)
            case "/v1/families/f1/kids/k1/pairing":
                MockReply(201, """
                {"code":"\(pairing)","expiresAt":"2026-10-27T18:05:00Z",\
                "kid":{"id":"k1","nickname":"Ana","avatar":"robot-4","grade":2,"createdAt":"2026-10-27T18:00:00Z"}}
                """)
            case "/v1/families/join": MockReply(200, familyJSON)
            default: MockReply(200, """
                {"session":{"token":"\(kidToken)","expiresAt":"2027-10-27T18:00:00Z"},\
                "kid":{"id":"k1","nickname":"Ana","avatar":"robot-4","grade":2,"createdAt":"2026-10-27T18:00:00Z"},\
                "family":{"id":"f1","name":"Popescu"}}
                """)
            }
        }

        let invitation = try await client.inviteParent(familyId: "f1", token: "t")
        let grant = try await client.createPairing(familyId: "f1", kidId: "k1", token: "t")
        let joined = try await client.join(code: code, token: "t")
        let session = try await client.redeemPairing(code: pairing)

        #expect(invitation.code == code)
        #expect(grant.code == pairing)
        #expect(grant.kid.nickname == "Ana")
        #expect(joined.id == "f1")
        #expect(session.token == kidToken)
        #expect(session.kid.nickname == "Ana")
        #expect(session.familyName == "Popescu")
        #expect(sent.last?.request.url?.path == "/v1/pairing/redeem")
        #expect(sent.last?.request.value(forHTTPHeaderField: "Authorization") == nil, "the code is the credential")
    }

    @Test(arguments: [
        (410, "pairing_code_invalid", FamiliesAPIError.codeInvalid),
        (410, "invitation_invalid", FamiliesAPIError.codeInvalid),
        (409, "too_many_kids", FamiliesAPIError.tooManyKids),
        (409, "already_in_family", FamiliesAPIError.alreadyInFamily),
        (429, "too_many_pairings", FamiliesAPIError.tooManyOpenCodes),
        (429, "too_many_invitations", FamiliesAPIError.tooManyOpenCodes),
        (401, "unauthorized", FamiliesAPIError.unauthorized),
        (404, "not_found", FamiliesAPIError.notFound),
    ])
    func errorsMapByCode(status: Int, code: String, expected: FamiliesAPIError) async {
        let client = api { _, _ in MockReply(status, #"{"error":{"code":"\#(code)"}}"#) }

        await #expect(throws: expected) { _ = try await client.createFamily(name: nil, token: "t") }
    }
}
