import AVFoundation
import Foundation
import Testing
@testable import ZapaCalls

/// The WebRTC side (LiveKit's WebRTC build): the FrameCryptor key ring follows the call key manager, and the
/// microphone goes out through an encrypting sender. No network, no microphone capture.
struct WebRTCMediaEngineTests {
    static var onIOS: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }

    @Test func installedKeysLandAtTheirRingIndex() {
        let keys = WebRTCFrameKeys()
        let key = CallKey.random(epoch: 17)

        keys.install(key)

        #expect(keys.exported(index: 1) == key.bytes, "epoch 17 → ring index 1")
    }

    /// On the iOS simulator (CI); on macOS the audio device waits minutes for a microphone.
    @Test(.enabled(if: WebRTCMediaEngineTests.onIOS))
    func theOfferCarriesOneSendOnlyAudioTrackWithAnEncryptingSender() async throws {
        let engine = WebRTCMediaEngine()

        let offer = try await engine.prepareLocalOfferForTests(trackName: "audio-dev-a")
        engine.frameKeys.useForSending(epoch: 18)

        #expect(offer.contains("m=audio"))
        #expect(offer.contains("a=sendonly"))
        #expect(!offer.contains("m=video"), "voice only in v1")
        #expect(engine.keysForTests.senderIndexes == [2])
        await engine.stop()
    }

    /// CallKit owns the audio session, so WebRTC must leave it alone from the start (manual audio, off until CallKit
    /// activates it), and calls need the voice-chat category. A call connected with no voice on either phone
    /// (Stefan, 2026-10-29).
    @Test(.enabled(if: WebRTCMediaEngineTests.onIOS))
    func callKitOwnsTheAudioSessionFromTheStart() async {
        #if os(iOS)
            let engine = WebRTCMediaEngine()
            #expect(CallAudio.webRTCAudioForTests == (manual: true, enabled: false))

            CallAudio.prepareForCall()

            #expect(AVAudioSession.sharedInstance().category == .playAndRecord)
            #expect(AVAudioSession.sharedInstance().mode == .voiceChat)
            await engine.stop()
        #endif
    }

    @Test func theKeyDerivationSettingsAreFixedForAndroid() {
        #expect(WebRTCFrameKeys.salt == Data("ZapaKid call frame key v1".utf8))
        #expect(CallKey.ringSize == 16)
    }
}
