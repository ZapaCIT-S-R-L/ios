import Foundation
import LibSignalClient
import Testing
@testable import ZapaKid
@testable import ZapaKidKit

/// A fake key directory that records what the app uploads.
actor FakeDeviceAPI: DeviceAPI {
    var identity: String?
    var registerResult: Result<Int, AuthAPIError> = .success(3)
    private(set) var uploads: [DeviceKeys] = []
    private(set) var lookups: [String] = []

    init(identity: String? = nil) {
        self.identity = identity
    }

    func set(registerResult: Result<Int, AuthAPIError>) {
        self.registerResult = registerResult
    }

    func registerDevice(_ keys: DeviceKeys, token _: String) async throws -> Int {
        uploads.append(keys)
        return try registerResult.get()
    }

    func accountIdentity(accountId: String, token _: String) async throws -> String? {
        lookups.append(accountId)
        return identity
    }

    func preKeyCount(token _: String) async throws -> PreKeyCount {
        PreKeyCount(preKeys: 0, pqPreKeys: 0)
    }
}

/// Registering this phone with the key directory (POST /v1/devices), as the Android app does.
@Suite(.serialized)
@MainActor
struct DeviceRegistrationTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)")
    let keychainService = "ro.zapakid.app.tests.identity.\(UUID().uuidString)"
    let session = Session(
        token: "zks_TEST", expiresAt: .distantFuture,
        parent: ParentProfile(id: "6f1c0e2a-0000-4000-8000-000000000001", email: nil, displayName: "TEST Parent")
    )

    func identityStore() -> LocalIdentityStore {
        LocalIdentityStore(keychain: .syncedIdentity(service: keychainService))
    }

    func registration(_ api: FakeDeviceAPI, reshare: IdentityReshare = NoReshare()) throws -> DeviceRegistration {
        try DeviceRegistration(
            api: api, identity: identityStore(), files: ProtectedFileStore(directory: directory), reshare: reshare,
            oneTimeCount: 3
        )
    }

    func cleanUp() {
        try? KeychainData.syncedIdentity(service: keychainService).clear()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func newAccountRegistersOnceWithKeysSignedByItsIdentity() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)

        let result = try await registration(api).run(session: session)

        #expect(result == .ready(deviceId: 3))
        let upload = try #require(await api.uploads.first)
        let identity = try #require(try identityStore().load())
        #expect(upload.identityKey == identity.keyPair.identityKey.serialize().base64EncodedString())
        let signed = try #require(Data(base64Encoded: upload.signedPreKey.publicKey))
        let signature = try #require(Data(base64Encoded: upload.signedPreKey.signature))
        #expect(try identity.keyPair.publicKey.verifySignature(message: signed, signature: signature))
        #expect(await api.lookups == [session.parent.id])

        let again = try await registration(api).run(session: session)

        #expect(again == .ready(deviceId: 3))
        #expect(await api.uploads.count == 1, "a registered phone does no more network work")
    }

    @Test func secondPhoneUsesTheSyncedIdentity() async throws {
        defer { cleanUp() }
        guard case let .ready(existing) = try identityStore().resolve(accountHasIdentity: false, reshare: NoReshare())
        else { throw CancellationError() }
        let key = existing.keyPair.identityKey.serialize().base64EncodedString()
        let reshare = RecordingReshare()
        let api = FakeDeviceAPI(identity: key)

        let result = try await registration(api, reshare: reshare).run(session: session)

        #expect(result == .ready(deviceId: 3))
        #expect(await api.uploads.first?.identityKey == key)
        #expect(reshare.requests == 0)
    }

    @Test func phoneWithoutTheIdentityWaitsAndUploadsNothing() async throws {
        defer { cleanUp() }
        let other = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
        let reshare = RecordingReshare()
        let api = FakeDeviceAPI(identity: other)

        let result = try await registration(api, reshare: reshare).run(session: session)

        #expect(result == .waitingForReshare)
        #expect(await api.uploads.isEmpty)
        #expect(reshare.requests == 1)
        #expect(try identityStore().load() == nil, "no new identity")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.isEmpty, "no keys made")
    }

    @Test func failedUploadIsRetriedWithTheSameKeys() async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)
        await api.set(registerResult: .failure(.network))

        let first = try await registration(api).run(session: session)
        await api.set(registerResult: .success(5))
        let second = try await registration(api).run(session: session)

        #expect(first == .failed(.network))
        #expect(second == .ready(deviceId: 5))
        let uploads = await api.uploads
        #expect(uploads.count == 2)
        #expect(uploads[0] == uploads[1], "the same keys, so the server can answer with the same device")
    }

    @Test(arguments: [
        (AuthAPIError.unauthorized, DeviceSetupResult.signedOut),
        (.identityMismatch, .failed(.identityMismatch)),
        (.rateLimited(retryAfter: 60), .failed(.rateLimited)),
        (.attestationFailed, .failed(.attestationFailed)),
        (.server(status: 409, code: "too_many_devices"), .failed(.server)),
    ])
    func uploadErrorsBecomeResults(error: AuthAPIError, expected: DeviceSetupResult) async throws {
        defer { cleanUp() }
        let api = FakeDeviceAPI(identity: nil)
        await api.set(registerResult: .failure(error))

        let result = try await registration(api).run(session: session)

        #expect(result == expected)
    }

    @Test func directoryKeyThatIsntOursIsNotOverwritten() async throws {
        defer { cleanUp() }
        _ = try identityStore().resolve(accountHasIdentity: false, reshare: NoReshare())
        let someoneElses = IdentityKeyPair.generate().identityKey.serialize().base64EncodedString()
        let api = FakeDeviceAPI(identity: someoneElses)

        let result = try await registration(api).run(session: session)

        #expect(result == .failed(.identityMismatch))
        #expect(await api.uploads.isEmpty, "never upload keys for an identity the directory doesn't know")
    }
}
