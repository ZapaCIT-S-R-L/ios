@preconcurrency import LiveKitWebRTC

extension WebRTCMediaEngine {
    /// Tests: a local offer with the microphone transceiver and its sender cryptor, without any network.
    func prepareLocalOfferForTests(trackName: String) async throws -> String {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        connection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: trackName)
        let initial = LKRTCRtpTransceiverInit()
        initial.direction = .sendOnly
        guard let transceiver = connection?.addTransceiver(with: track, init: initial),
              let cryptor = LKRTCFrameCryptor(
                  factory: factory, rtpSender: transceiver.sender, participantId: trackName, algorithm: .aesGcm,
                  keyProvider: keys.provider
              )
        else { throw CallsAPIError.invalidResponse }
        cryptor.enabled = true
        keys.addSender(cryptor)
        return try await makeOffer()
    }

    var keysForTests: WebRTCFrameKeys {
        keys
    }
}
