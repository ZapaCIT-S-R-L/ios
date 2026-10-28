# iOS security design

How the app keeps chats private and the account safe. Security comes first, then cost, then availability.
ZapaKid (the company and its servers) must never be able to decrypt a chat. No external audit is planned before
launch, so all chat cryptography stays inside [libsignal](https://github.com/signalapp/libsignal): the app adds no
cryptographic primitives of its own.

## In place

| Area | Rule | Where |
| --- | --- | --- |
| Transport | App Transport Security with no exceptions (no `NSAppTransportSecurity` key); API session TLS 1.3 minimum, no cookies, no cache | `HTTPAuthAPI.secureConfiguration()`, `AppSecurityTests` |
| Session | API token in the Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable | `KeychainSessionStore` |
| Files at rest | Data Protection class Complete for every file the app writes (`com.apple.developer.default-data-protection`) | `ZapaKid.entitlements` |
| Sign-in | One-time server nonce (`POST /v1/auth/nonce`); Apple and Google tokens carry its SHA-256, the API gets the raw nonce and rejects replays. Google uses PKCE, no client secret, ephemeral browser session | `AuthModel`, `SignInNonce`, `GoogleSignIn` |
| Minors | A shared age range that doesn't show 18+, or a declined one, is stopped before anything is sent; the API also refuses them (`403 minor_not_allowed`, `403 age_declined`) | `AuthModel.signIn` |
| UI tests | The stub backend is compiled into Debug builds only | `UITestStubs.swift` (`#if DEBUG`) |
| Chat keys | libsignal (CocoaPod, pinned tag + prebuilt checksum) makes every key. Identity key pair and registration ID: one per account, the one deliberately synchronizable Keychain item (iCloud Keychain, when unlocked); a phone without it waits for a re-share, never makes a new identity; private prekeys, Kyber prekeys and sessions in Data-Protection-Complete files excluded from backups; only public keys and their signatures are published | `ZapaKid/Keys/` |
| Accounts on one phone | Everything kept for an account (synced identity item, key directory, device ID) is keyed by the account ID, and the identity item carries the account ID and is refused in another account's slot; a second account never reuses the first one's identity or device | `AccountKeys` |
| Key changes | A peer whose identity key changed can't be sent to until the parent acknowledges the change (also after a restart and a reinstall: the trusted-peer list is a synced Keychain item of the account, next to the identity); receiving still works so the warning can show | `ZapaKidProtocolStore`, `PeerTrustStore` |
| Supply chain | Exact versions (`Package.resolved` committed), actions pinned by commit SHA, images by digest; OSV-Scanner on every PR and daily; Dependabot security updates; SBOM on every release; CodeQL; gitleaks | `.github/` |

## Rules for the next slices

- **Keys:** one libsignal identity per account. The identity key pair is the one deliberately synchronizable Keychain
  item (iCloud Keychain, end-to-end encrypted by Apple, readable when unlocked), so the parent's phones and a
  reinstall share it; a phone without it waits for a re-share from another family phone. Prekeys and sessions stay
  this-device-only. Signing in to the account alone never restores keys.
- **Chat data at rest:** in files with `NSFileProtectionComplete` (the default above); no chat content in
  `UserDefaults`, caches or the pasteboard by default.
- **No chat content** in logs, crash reports, analytics or push payloads. Pushes carry only an opaque "new message"
  signal; a Notification Service Extension decrypts on the phone.

## App Attest

Goal: the API serves only genuine copies of the app on real Apple devices (DeviceCheck App Attest). Decided
2026-10-26: **required in production**. Endpoints from `openapi.yaml` in ZapaCIT-S-R-L/zapakid-api (tag
`App attestation`); the client is `AppAttestor` (ZapaKidKit, `Auth/AppAttest.swift`):

1. Once per install (parents and kids share it): `DCAppAttestService.shared.generateKey()` → key ID.
2. `POST /v1/attestation/challenge` → `{challenge, expiresAt}` (single use, 5 minutes, no session needed).
3. `attestKey(keyID, clientDataHash: SHA256(challenge))` → attestation object.
   `POST /v1/attestation/apple {keyId, attestationObject, challenge}` → 204. The API verifies the chain to Apple's
   App Attest root, App ID `9572LYGZ7S.ro.zapakid.app`, key ID, counter 0, production `aaguid` in production.
   Only then is the key ID kept in the Keychain (`WhenUnlockedThisDeviceOnly`, never synced).
4. Attested calls carry `ZapaKid-Attestation: v1 keyId=<base64> assertion=<base64>`, the assertion from
   `generateAssertion(keyID, clientDataHash: SHA256(exact body bytes))`; the API checks the signature and that the
   counter goes up. Now: `POST /v1/devices` and `PUT /v1/keys/identity` (parents and kids). Still to do: sign-in
   (`POST /v1/auth/apple`, `/v1/auth/google`) and `POST /v1/pairing/redeem`.
5. Key loss (`DCError.invalidKey`, e.g. a Keychain item that outlived a reinstall) or a key the API refuses
   (`403 attestation_failed`: unknown, or unused for 180 days): one new key and one more try, then the refusal is
   final (the setup screen says so, no retry loop). App Attest protects the API; chat content stays end-to-end
   encrypted either way.
6. Simulator (no App Attest): only debug builds send the request without the header; the API accepts that only on
   staging (`ATTESTATION_POLICY=allowlist`) for allowlisted test accounts. Release builds never skip.
7. No entitlement needed: TestFlight and App Store builds use the production environment whatever the entitlement
   says (docs/testflight.md); development builds use the development environment, which staging accepts.

## Planned: key verification (later PR)

- **Identity keys never change silently** (API tag `Draft: Devices and keys`): the app checks every peer key
  itself with libsignal's `IdentityKeyStore`, and the server also announces changes (`identity_changed`).
- **Safety numbers** from libsignal (`Fingerprint` / `NumericFingerprint` and `ScannableFingerprint`): each pair of
  parents can compare a 60-digit number or scan each other's QR code in person. A verified contact gets a visible
  "verified" mark.
- **Key-change warning:** when a contact's identity key changes (new phone, reinstall), the chat shows a clear system
  message and, for a verified contact, blocks sending until the parent acknowledges it (re-verify or accept).
- Kids' phones are verified at pairing: the pairing QR carries the parent's identity key fingerprint, so the kid's
  phone checks the parent's key out of band (no trust on first use) and kids have no extra step.

Tests: unit tests on the verification state machine; a UI test for the key-change banner with a stubbed key store.
