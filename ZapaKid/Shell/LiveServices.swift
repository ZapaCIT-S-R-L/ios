import Foundation
import ZapaCalls
import ZapaChat
import ZapaKidKit

/// The real chat and call services (staging). Messages and call keys are sealed with libsignal once this phone is
/// registered with the key directory; until then they refuse (nothing is ever sent unencrypted).
/// Audio is WebRTC (Cloudflare Realtime) with per-frame AES-GCM.
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
        // swiftlint:disable:next force_unwrapping
        let bundles = HTTPPreKeyBundles(baseURL: URL(string: ZapaKidKit.apiBaseURL)!, session: .shared) {
            await MainActor.run { auth.sessionToken }
        }
        let box = SessionsBox(SecureSessions.make(accountId: me, bundles: bundles))
        // Only real sealers (Release*Sealer): without a registered device they refuse, never send in the clear.
        let messageSealer: any ReleaseMessageSealer = LibsignalMessageSealer(box: box)
        let callSealer: any ReleaseCallKeySealer = LibsignalCallKeySealer(box: box)
        #if targetEnvironment(simulator)
            let system: CallSystem = InAppCallSystem()
        #else
            let system: CallSystem = CallKitSystem()
        #endif
        let services = AppServices(
            me: me, canStartChats: !kid,
            chat: ChatModel(me: me, api: chatAPI, sealer: messageSealer, store: store),
            people: [], log: InMemoryCallLog(), system: system
        ) { services in
            let engine = WebRTCMediaEngine()
            // CallKit owns the audio session; WebRTC starts audio when CallKit activates it.
            services.calls.onAudioSessionChange = { [weak engine] active in engine?.audioSession(active: active) }
            let device = box.sessions.map {
                LibsignalCallKeySealer.deviceName(account: me, device: Int($0.local.deviceId))
            } ?? me
            return CallController(
                me: device, api: callsAPI, engine: engine, sealer: callSealer,
                directory: { [weak services] account in services?.peer(account) }
            )
        }
        services.prepare = {
            // Register this phone with the key directory (once), then seal with its sessions.
            guard box.sessions == nil, let token = auth.sessionToken else { return }
            let session = Session(
                token: token, expiresAt: .distantFuture, parent: ParentProfile(id: me, email: nil, displayName: nil)
            )
            let registration = DeviceRegistration(api: HTTPAuthAPI.staging, reshare: WaitForReshare())
            if case .ready = await registration.run(session: session) {
                box.sessions = SecureSessions.make(accountId: me, bundles: bundles)
            }
        }
        return services
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

/// Another family phone must re-share the identity (the re-share flow comes later); nothing to do here.
struct WaitForReshare: IdentityReshare {
    func requestReshare() {}
}
