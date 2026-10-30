import Foundation
import os
import ZapaCalls
import ZapaChat
import ZapaKidKit

/// The real chat and call services (staging). Messages and call keys are sealed with libsignal once this phone is
/// registered with the key directory; until then they refuse (nothing is ever sent unencrypted).
/// Audio is WebRTC (Cloudflare Realtime) with per-frame AES-GCM.
@MainActor
enum LiveServices {
    static func make(me: String, kid: Bool, auth: AuthModel) -> AppServices {
        let endKidSession = kidSessionEnd(me: me, auth: auth)
        let token = chatToken(kid: kid, auth: auth, endKidSession: endKidSession)
        // swiftlint:disable:next force_unwrapping
        let chatAPI = HTTPChatAPI(baseURL: HTTPChatAPI.stagingURL!, token: token)
        // swiftlint:disable:next force_unwrapping
        let callsAPI = HTTPCallsAPI(baseURL: HTTPCallsAPI.stagingURL!, token: token)
        let store = chatStore(me: me, kid: kid)
        // swiftlint:disable:next force_unwrapping
        let bundles = HTTPPreKeyBundles(baseURL: URL(string: ZapaKidKit.apiBaseURL)!, session: .shared) {
            await MainActor.run { auth.sessionToken }
        }
        let box = SessionsBox(SecureSessions.make(accountId: me, kid: kid, bundles: bundles))
        // Only real sealers (Release*Sealer): without a registered device they refuse, never send in the clear.
        let messageSealer: any ReleaseMessageSealer = LibsignalMessageSealer(box: box)
        let callSealer: any ReleaseCallKeySealer = LibsignalCallKeySealer(box: box)
        #if targetEnvironment(simulator)
            let system: CallSystem = InAppCallSystem()
        #else
            let system: CallSystem = CallKitSystem()
        #endif
        let services = AppServices(
            me: me,
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
        // This phone's device ID, once it is registered.
        let registeredDevice: () -> Int? = {
            (try? AccountKeys.app(accountId: me, kid: kid)).flatMap(DeviceRegistration.registeredDeviceId)
        }
        // The VoIP token goes to the server once this phone is registered (in either order).
        let pushSync = PushTargetSync(
            api: AppAttestation.devicesAPI, token: { auth.sessionToken }, deviceId: registeredDevice
        )
        // The APNs token for chat notifications: its own target and endpoint, synced the same way.
        let alertSync = PushTargetSync(
            api: AppAttestation.devicesAPI, channel: .alert, token: { auth.sessionToken }, deviceId: registeredDevice
        )
        AlertPushes.onToken = { hex in Task { await alertSync.tokenChanged(hex) } }
        services.setup = deviceSetup(me: me, kid: kid, auth: auth, endKidSession: endKidSession) { [weak services] in
            box.sessions = SecureSessions.make(accountId: me, kid: kid, bundles: bundles)
            Task { await pushSync.deviceRegistered() }
            Task { await alertSync.deviceRegistered() }
            guard let services else { return }
            Task {
                await services.chat.loadConversations()
            }
        }
        startVoIPPushes(services: services, pushSync: pushSync)
        services.calls.onFinished = { [weak services] entry in
            guard let services, let result = CallResult(entry) else { return }
            Task { await services.chat.recordCallResult(callId: entry.id, result: result) }
        }
        return services
    }

    private static func chatStore(me: String, kid: Bool) -> ChatStore {
        do {
            return try EncryptedChatStore(
                directory: ChatStoreLocation.directory(accountId: me, kid: kid),
                key: ChatStoreKey.loadOrCreate(account: ChatStoreLocation.keychainAccount(accountId: me, kid: kid))
            )
        } catch {
            // Not silent: history kept only in memory is gone at the next start.
            Logger(subsystem: "ro.zapakid.app", category: "chat-store").error(
                "encrypted chat store unavailable, using memory: \(String(describing: error), privacy: .public)"
            )
            return InMemoryChatStore()
        }
    }

    private static func startVoIPPushes(services: AppServices, pushSync: PushTargetSync) {
        #if canImport(PushKit)
            // Start PushKit at sign-in, so a killed app is woken for an incoming call.
            let pushes = VoIPPushes(coordinator: services.calls)
            pushes.onToken = { data in
                let hex = data.map(PushTargetSync.hex)
                Task { await pushSync.voipTokenChanged(hex) }
            }
            pushes.register()
            services.voipPushes = pushes
        #endif
    }

    /// A kid session the API refuses (401): wipe this kid's keys and chat history (only the kid's, never a
    /// parent's on the same phone), and go back to pairing.
    private static func kidSessionEnd(me: String, auth: AuthModel) -> @MainActor () -> Void {
        {
            try? AccountKeys.app(accountId: me, kid: true).wipe()
            ChatStoreLocation.wipeKid(accountId: me) { account in
                try? KeychainData(service: ChatStoreKey.service, account: account).clear()
            }
            auth.kidSessionEnded()
        }
    }

    /// Whether `me` is still the signed-in account (a parent, or a kid phone), so work started for it may go on.
    static func isCurrent(_ state: AuthState, me: String, kid: Bool) -> Bool {
        switch state {
        case let .signedIn(parent): !kid && parent.id == me
        case let .kid(session): kid && session.kid.id == me
        default: false
        }
    }

    /// The chat token for chat and calls; a 401 on a kid session ends it.
    private static func chatToken(
        kid: Bool, auth: AuthModel, endKidSession: @escaping @MainActor () -> Void
    ) -> @Sendable () async throws -> String {
        let tokens = ChatTokenProvider(
            // swiftlint:disable:next force_unwrapping
            api: HTTPChatTokenAPI(baseURL: URL(string: ZapaKidKit.apiBaseURL)!),
            session: { await MainActor.run { auth.sessionToken } }
        )
        return {
            do {
                return try await tokens.token()
            } catch AuthAPIError.unauthorized where kid {
                await MainActor.run { endKidSession() }
                throw AuthAPIError.unauthorized
            }
        }
    }

    /// Registers this phone (parent or kid) with the key directory, retrying calmly; `ready` when it's done.
    private static func deviceSetup(
        me: String, kid: Bool, auth: AuthModel, endKidSession: @escaping @MainActor () -> Void,
        ready: @escaping @MainActor () -> Void
    ) -> DeviceSetup {
        let pairedAt: Date? = if case let .kid(session) = auth.state {
            session.pairedAt
        } else {
            nil
        }
        let registration = DeviceRegistration(
            api: AppAttestation.devicesAPI, keyspace: { try AccountKeys.app(accountId: $0, kid: kid) },
            reshare: WaitForReshare()
        )
        let setup = DeviceSetup(
            register: {
                // A loop from an earlier session never registers with the next account's token.
                guard isCurrent(auth.state, me: me, kid: kid) else { return .superseded }
                guard let token = auth.sessionToken else { return .signedOut }
                if kid {
                    return await registration.runKid(accountId: me, token: token, pairedAt: pairedAt)
                }
                let session = Session(
                    token: token, expiresAt: .distantFuture, parent: ParentProfile(id: me, email: nil, displayName: nil)
                )
                return await registration.run(session: session)
            },
            onSignedOut: {
                if kid {
                    endKidSession()
                } else {
                    Task { await auth.logout() }
                }
            }
        )
        setup.onReady = { _ in ready() }
        return setup
    }
}

/// Where an account's encrypted chat store lives. A parent keeps the original location; a kid session gets its own,
/// so ending it wipes only the kid's history.
enum ChatStoreLocation {
    static func directory(accountId: String, kid: Bool, root: URL = .applicationSupportDirectory) -> URL {
        root.appending(path: kid ? "chats-kid-\(accountId)" : "chats")
    }

    static func keychainAccount(accountId: String, kid: Bool) -> String {
        kid ? "key-kid-\(accountId)" : "key"
    }

    /// Removes a kid's chat store and passes its Keychain account to `clearKey`.
    static func wipeKid(
        accountId: String, root: URL = .applicationSupportDirectory, clearKey: (String) -> Void
    ) {
        try? FileManager.default.removeItem(at: directory(accountId: accountId, kid: true, root: root))
        clearKey(keychainAccount(accountId: accountId, kid: true))
    }
}

/// The key for an encrypted chat store: 32 random bytes in the Keychain, this device only.
enum ChatStoreKey {
    static let service = "ro.zapakid.app.chat-store"

    static func loadOrCreate(account: String) throws -> Data {
        let keychain = KeychainData(service: service, account: account)
        if let key = try keychain.load(), key.count == 32 {
            Logger(subsystem: "ro.zapakid.app", category: "chat-store").info("chat key found")
            return key
        }
        Logger(subsystem: "ro.zapakid.app", category: "chat-store").error("chat key missing, creating a new one")
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
