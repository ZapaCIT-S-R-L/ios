import Foundation
import ZapaCalls
import ZapaChat
import ZapaKidKit

/// The real chat and call services (staging). Two pieces arrive in their own PRs and refuse until then:
/// the libsignal message/call-key sealers (stacked on the key-setup PRs) and the WebRTC media engine.
@MainActor
enum LiveServices {
    static func make(me: String, kid: Bool, auth: AuthModel) -> AppServices {
        let tokens = ChatTokenProvider(
            // swiftlint:disable:next force_unwrapping
            api: HTTPChatTokenAPI(baseURL: URL(string: ZapaKidKit.apiBaseURL)!),
            session: { await MainActor.run { auth.sessionToken } }
        )
        let token: @Sendable () async throws -> String = { try await tokens.token() }
        // swiftlint:disable:next force_unwrapping
        let chatAPI = HTTPChatAPI(baseURL: HTTPChatAPI.stagingURL!, token: token)
        // swiftlint:disable:next force_unwrapping
        let callsAPI = HTTPCallsAPI(baseURL: HTTPCallsAPI.stagingURL!, token: token)
        let store: ChatStore = (try? EncryptedChatStore(
            directory: URL.applicationSupportDirectory.appending(path: "chats"), key: ChatStoreKey.loadOrCreate()
        )) ?? InMemoryChatStore()
        #if DEBUG
            // Debug builds without libsignal yet: the sealers refuse, so nothing is ever sent unencrypted.
            let messageSealer: any MessageSealer = PendingMessageSealer()
            let callSealer: any CallKeySealer = PendingCallKeySealer()
        #else
            // Release builds take only real sealers (ReleaseMessageSealer / ReleaseCallKeySealer, libsignal).
            #error("No real MessageSealer/CallKeySealer is wired in: release builds need the libsignal sealers.")
        #endif
        #if targetEnvironment(simulator)
            let system: CallSystem = InAppCallSystem()
        #else
            let system: CallSystem = CallKitSystem()
        #endif
        return AppServices(
            me: me, canStartChats: !kid,
            chat: ChatModel(me: me, api: chatAPI, sealer: messageSealer, store: store),
            people: [], log: InMemoryCallLog(), system: system
        ) { _ in
            CallController(me: me, api: callsAPI, engine: PendingMediaEngine(), sealer: callSealer)
        }
    }
}

/// The key for the encrypted chat store: 32 random bytes in the Keychain, this device only.
enum ChatStoreKey {
    static func loadOrCreate() throws -> Data {
        let keychain = KeychainData(service: "ro.zapakid.app.chat-store", account: "key")
        if let key = try keychain.load(), key.count == 32 {
            return key
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainData.Failure(status: errSecAllocate)
        }
        let key = Data(bytes)
        try keychain.save(key)
        return key
    }
}

enum PendingCrypto: Error {
    /// libsignal isn't wired into chat and calls yet (its own PR, stacked on the key-setup PRs).
    case notReady
}

#if DEBUG
    /// Refuses until the libsignal sealer replaces it: nothing is ever sent unencrypted. Debug builds only.
    struct PendingMessageSealer: MessageSealer {
        func seal(_: Data, for _: Conversation, me _: String) async throws -> [OutgoingEnvelope] {
            throw PendingCrypto.notReady
        }

        func open(_: Envelope) async throws -> Data {
            throw PendingCrypto.notReady
        }
    }

    struct PendingCallKeySealer: CallKeySealer {
        func seal(_: Data, toDevice _: String) async throws -> Data {
            throw PendingCrypto.notReady
        }

        func open(_: Data, fromDevice _: String) async throws -> Data {
            throw PendingCrypto.notReady
        }
    }
#endif

/// Until the WebRTC engine PR: a call can ring and signal, but carries no audio.
final class PendingMediaEngine: CallMediaEngine, @unchecked Sendable {
    let events: AsyncStream<MediaEvent>
    let frameKeys: FrameKeyInstaller = NoFrameKeys()

    init() {
        events = AsyncStream { $0.finish() }
    }

    func start(callId _: String, iceServers _: [IceServer], api _: CallsAPI, trackName _: String) async throws {
        throw PendingCrypto.notReady
    }

    func subscribe(_: [TrackRef]) async throws {}
    func unsubscribe(_: [TrackRef]) async {}
    func setMuted(_: Bool) {}
    func setSpeakerOn(_: Bool) {}
    func stop() async {}

    private struct NoFrameKeys: FrameKeyInstaller {
        func install(_: CallKey) {}
        func useForSending(epoch _: UInt32) {}
    }
}
