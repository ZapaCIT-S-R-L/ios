import Foundation
import Testing
@testable import ZapaKidKit

/// Connecting families: a parent makes a code or accepts one, then shares or unshares their kids, or removes the
/// connection.
@MainActor
struct ConnectionsModelTests {
    let api = FakeConnectionsAPI()

    func model() -> ConnectionsModel {
        ConnectionsModel(api: api, token: { "zks_t" })
    }

    @Test func loadingListsTheConnections() async {
        api.connections = [FakeConnectionsAPI.grandparents]
        let connections = model()

        await connections.load()

        #expect(connections.connections == [FakeConnectionsAPI.grandparents])
    }

    @Test func aCodeIsMadeForAnotherFamily() async {
        let connections = model()

        let invitation = await connections.invite()

        #expect(invitation?.code == "zkc_" + String(repeating: "a", count: 43))
        #expect(api.calls == ["invite"])
    }

    @Test func acceptingAFamilysCodeAddsTheConnection() async {
        api.connections = []
        let connections = model()

        let accepted = await connections.accept(code: "zkc_" + String(repeating: "b", count: 43))

        #expect(accepted)
        #expect(connections.connections.map(\.id) == ["c_grandparents"])
    }

    @Test func aScannedLinkIsAcceptedByItsCode() async {
        let connections = model()
        let code = "zkc_" + String(repeating: "c", count: 43)

        let accepted = await connections.accept(code: "https://zapakid.ro/connect#" + code)

        #expect(accepted)
        #expect(api.calls == ["accept"])
    }

    @Test func aBadCodeIsRefusedWithoutACall() async {
        let connections = model()

        let accepted = await connections.accept(code: "not a code")

        #expect(!accepted)
        #expect(api.calls.isEmpty)
        #expect(connections.errorMessage != nil)
    }

    @Test func sharingAKidShowsItAsShared() async {
        api.connections = [FakeConnectionsAPI.grandparents]
        let connections = model()
        await connections.load()

        await connections.setShared(true, kidId: "k_ana", in: "c_grandparents")

        #expect(connections.connections.first?.sharedKids.mine == ["k_ana"])
        #expect(api.calls == ["share k_ana"])
    }

    @Test func unsharingAKidRemovesIt() async {
        api.connections = [FakeConnectionsAPI.grandparents]
        let connections = model()
        await connections.load()

        await connections.setShared(false, kidId: "k_ana", in: "c_grandparents")

        #expect(connections.connections.first?.sharedKids.mine.isEmpty == true)
        #expect(api.calls == ["unshare k_ana"])
    }

    @Test func removingAConnectionDropsIt() async {
        api.connections = [FakeConnectionsAPI.grandparents]
        let connections = model()
        await connections.load()

        await connections.remove("c_grandparents")

        #expect(connections.connections.isEmpty)
        #expect(api.calls == ["remove c_grandparents"])
    }
}

/// Stands in for the account API: answers from fixed data and records each call.
final class FakeConnectionsAPI: ConnectionsAPI, @unchecked Sendable {
    static let grandparents = Connection(
        id: "c_grandparents",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        family: ConnectedFamily(id: "f2", name: nil, parents: [ConnectedParent(id: "p9", displayName: "Maria")]),
        sharedKids: SharedKids(mine: [], theirs: [])
    )

    var connections: [Connection] = []
    var calls: [String] = []

    func list(token: String) async throws -> [Connection] {
        connections
    }

    func invite(token: String) async throws -> ConnectionInvitation {
        calls.append("invite")
        return ConnectionInvitation(code: "zkc_" + String(repeating: "a", count: 43), expiresAt: Date())
    }

    func accept(code: String, token: String) async throws -> Connection {
        calls.append("accept")
        let connection = Connection(
            id: "c_grandparents",
            createdAt: Date(),
            family: ConnectedFamily(id: "f2", name: nil, parents: []),
            sharedKids: SharedKids(mine: [], theirs: [])
        )
        connections.append(connection)
        return connection
    }

    func share(connectionId: String, kidId: String, token: String) async throws {
        calls.append("share \(kidId)")
        if let index = connections.firstIndex(where: { $0.id == connectionId }) {
            connections[index].sharedKids.mine.append(kidId)
        }
    }

    func unshare(connectionId: String, kidId: String, token: String) async throws {
        calls.append("unshare \(kidId)")
        if let index = connections.firstIndex(where: { $0.id == connectionId }) {
            connections[index].sharedKids.mine.removeAll { $0 == kidId }
        }
    }

    func remove(connectionId: String, token: String) async throws {
        calls.append("remove \(connectionId)")
        connections.removeAll { $0.id == connectionId }
    }
}
