#if canImport(PushKit) && os(iOS)
    import PushKit

    /// VoIP pushes (PushKit). Every push must reach CallKit before `completion` runs, or iOS stops delivering
    /// them; the coordinator does that. The token goes to the backend via `onToken` (APNs credentials: ios #27).
    @MainActor
    public final class VoIPPushes: NSObject, @preconcurrency PKPushRegistryDelegate {
        private let registry = PKPushRegistry(queue: .main)
        private let coordinator: CallCoordinator
        public var onToken: ((Data?) -> Void)?

        public init(coordinator: CallCoordinator) {
            self.coordinator = coordinator
            super.init()
        }

        public func register() {
            registry.delegate = self
            registry.desiredPushTypes = [.voIP]
        }

        public func pushRegistry(_: PKPushRegistry, didUpdate credentials: PKPushCredentials, for _: PKPushType) {
            onToken?(credentials.token)
        }

        public func pushRegistry(_: PKPushRegistry, didInvalidatePushTokenFor _: PKPushType) {
            onToken?(nil)
        }

        public func pushRegistry(
            _: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for _: PKPushType,
            completion: @escaping () -> Void
        ) {
            let push = IncomingCallPush(payload: payload.dictionaryPayload)
            Task {
                if let push {
                    await coordinator.handle(push)
                } else {
                    await coordinator.handleInvalidPush()
                }
                completion()
            }
        }
    }
#endif
