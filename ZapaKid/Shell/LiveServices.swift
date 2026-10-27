import Foundation
import ZapaCalls
import ZapaChat
import ZapaKidKit

/// The real chat and call services (staging). Messages and call keys are sealed with libsignal once this phone is
/// registered with the key directory; until then the pending sealers refuse (nothing is ever sent unencrypted).
/// Audio is WebRTC (Cloudflare Realtime) with per-frame AES-GCM.
@MainActor
enum LiveServices {
    static func make(me: String, auth: AuthModel) -> AppServices {
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
        // swiftlint:disable:next force_unwrapping
        let bundles = HTTPPreKeyBundles(baseURL: URL(string: ZapaKidKit.apiBaseURL)!, session: .shared) {
            await MainActor.run { auth.sessionToken }
        }
        let sessions = SecureSessions.make(accountId: me, bundles: bundles)
        let messageSealer: MessageSealer = sessions
            .map { LibsignalMessageSealer(sessions: $0) } ?? PendingMessageSealer()
        let callSealer: CallKeySealer = sessions.map { LibsignalCallKeySealer(sessions: $0) } ?? PendingCallKeySealer()
        let callDevice = sessions
            .map { LibsignalCallKeySealer.deviceName(account: me, device: Int($0.local.deviceId)) } ?? me
        #if targetEnvironment(simulator)
            let system: CallSystem = InAppCallSystem()
        #else
            let system: CallSystem = CallKitSystem()
        #endif
        return AppServices(
            me: me,
            chat: ChatModel(me: me, api: chatAPI, sealer: messageSealer, store: store),
            people: [], log: InMemoryCallLog(), system: system
        ) { services in
            let engine = WebRTCMediaEngine()
            // CallKit owns the audio session; WebRTC starts audio when CallKit activates it.
            services.calls.onAudioSessionChange = { [weak engine] active in engine?.audioSession(active: active) }
            return CallController(me: callDevice, api: callsAPI, engine: engine, sealer: callSealer)
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

/// Refuses until the libsignal sealer replaces it: nothing is ever sent unencrypted.
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
