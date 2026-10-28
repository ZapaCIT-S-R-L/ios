import Foundation
import ZapaKidKit

/// The API client for registering this phone (parents and kids): `POST /v1/devices` and `PUT /v1/keys/identity`
/// carry App Attest (`ZapaKid-Attestation`), which production requires. One attestor for the whole app, so two
/// sessions never register two keys at once.
enum AppAttestation {
    static let attestor = AppAttestor(
        service: DeviceCheckAppAttest(),
        keys: KeychainAppAttestKeyStore(),
        api: HTTPAuthAPI.staging,
        skipWhenUnsupported: skipWhenUnsupported
    )

    /// Only debug builds skip attestation where App Attest isn't available (the simulator); the API then accepts
    /// them only on staging, for allowlisted test accounts.
    static var skipWhenUnsupported: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// The staging API with attestation on device registration.
    static var devicesAPI: HTTPAuthAPI {
        let staging = HTTPAuthAPI.staging
        return HTTPAuthAPI(baseURL: staging.baseURL, attestor: attestor)
    }
}
