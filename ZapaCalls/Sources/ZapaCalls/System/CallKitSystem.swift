#if canImport(CallKit) && os(iOS)
    import AVFoundation
    import CallKit

    /// CallKit: the native incoming call screen (also on the lock screen), Bluetooth and the audio session.
    /// Calls stay out of the phone's Recents, so family names never leave the app.
    @MainActor
    public final class CallKitSystem: NSObject, CallSystem, @preconcurrency CXProviderDelegate {
        public weak var actions: CallSystemActions?
        private let provider: CXProvider
        private let callController = CXCallController()

        public static func configuration() -> CXProviderConfiguration {
            let config = CXProviderConfiguration()
            config.supportsVideo = false
            config.maximumCallGroups = 1
            config.maximumCallsPerCallGroup = 1
            config.supportedHandleTypes = [.generic]
            config.includesCallsInRecents = false
            return config
        }

        override public init() {
            provider = CXProvider(configuration: Self.configuration())
            super.init()
            provider.setDelegate(self, queue: nil)
        }

        public func reportIncoming(uuid: UUID, callerName: String) async throws {
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: callerName)
            update.localizedCallerName = callerName
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsDTMF = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        }

        public func startOutgoing(uuid: UUID, name: String) async throws {
            let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
            try await callController.request(CXTransaction(action: action))
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
        }

        public func reportConnected(uuid: UUID) {
            provider.reportOutgoingCall(with: uuid, connectedAt: nil)
        }

        public func reportEnded(uuid: UUID, reason: CallSystemEndReason) {
            let cxReason: CXCallEndedReason = switch reason {
            case .remoteEnded: .remoteEnded
            case .unanswered: .unanswered
            case .failed: .failed
            case .declinedElsewhere: .declinedElsewhere
            }
            provider.reportCall(with: uuid, endedAt: nil, reason: cxReason)
        }

        // MARK: CXProviderDelegate

        public func providerDidReset(_: CXProvider) {}

        public func provider(_: CXProvider, perform action: CXAnswerCallAction) {
            Task {
                await actions?.answer(action.callUUID)
                action.fulfill()
            }
        }

        public func provider(_: CXProvider, perform action: CXEndCallAction) {
            Task {
                await actions?.end(action.callUUID)
                action.fulfill()
            }
        }

        public func provider(_: CXProvider, perform action: CXSetMutedCallAction) {
            Task {
                await actions?.setMuted(action.callUUID, action.isMuted)
                action.fulfill()
            }
        }

        public func provider(_: CXProvider, perform action: CXStartCallAction) {
            action.fulfill()
        }

        public func provider(_: CXProvider, didActivate _: AVAudioSession) {
            actions?.audioSession(active: true)
        }

        public func provider(_: CXProvider, didDeactivate _: AVAudioSession) {
            actions?.audioSession(active: false)
        }
    }
#endif
