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
| Supply chain | Exact versions (`Package.resolved` committed), actions pinned by commit SHA, images by digest; OSV-Scanner on every PR and daily; Dependabot security updates; SBOM on every release; CodeQL; gitleaks | `.github/` |

## Rules for the next slices

- **Keys:** libsignal identity and session keys in the Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  The only exception is the chat-history backup key: one deliberately synchronizable item (iCloud Keychain, end-to-end
  encrypted by Apple), so a new phone of the same parent gets the history back. Signing in to the account alone never
  restores keys.
- **Chat data at rest:** in files with `NSFileProtectionComplete` (the default above); no chat content in
  `UserDefaults`, caches or the pasteboard by default.
- **No chat content** in logs, crash reports, analytics or push payloads. Pushes carry only an opaque "new message"
  signal; a Notification Service Extension decrypts on the phone.

## Planned: App Attest (later PR, required on sign-in before launch)

Goal: the API serves only genuine copies of the app on real Apple devices (DeviceCheck App Attest). Decided
2026-10-26: **required on sign-in from launch**. Endpoints from `openapi.yaml` in ZapaCIT-S-R-L/api (tag
`Draft: App attestation`, still a draft there):

1. First launch: `DCAppAttestService.shared.isSupported` (false on the simulator: UI tests keep the stub backend;
   staging needs a debug path, to be agreed with the API). `generateKey()` → key ID, kept in the Keychain
   (`WhenUnlockedThisDeviceOnly`).
2. `POST /v1/attestation/challenge` → `{challenge, expiresAt}` (single use, 5 minutes, no session needed).
3. `attestKey(keyID, clientDataHash: SHA256(challenge))` → attestation object.
   `POST /v1/attestation/apple {keyId, attestationObject, challenge}` → 204. The API verifies the chain to Apple's
   App Attest root, App ID `9572LYGZ7S.com.zapacit.cuzaai`, key ID, counter 0, production `aaguid` in production.
4. Sign-in and other sensitive calls carry an assertion in the `ZapaKid-Attestation` header:
   `generateAssertion(keyID, clientDataHash: SHA256(request body))`; the API checks the signature and that the
   counter goes up. A refused client gets `403 attestation_failed` (the sign-in client already maps it to a
   message).
5. Reinstall or key loss: generate and attest a new key. App Attest protects the API; chat content stays end-to-end
   encrypted either way.
6. Entitlement `com.apple.developer.devicecheck.appattest-environment` (`development` for Debug, `production` for
   App Store builds).

Tests: the attestation client against a mocked API (as `HTTPAuthAPITests`), `DCAppAttestService` behind a protocol
with a fake, and a sign-in test that the header is sent.

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
