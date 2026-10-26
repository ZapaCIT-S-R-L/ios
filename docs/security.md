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
| Sign-in | Apple and Google ID tokens carry SHA-256(nonce); the API gets the raw nonce and rejects replays. Google uses PKCE, no client secret, ephemeral browser session | `SignInNonce`, `GoogleSignIn` |
| Minors | A parent known to be under 18 (Declared Age Range) is blocked before anything is sent; the API also refuses minors (403 `minor`) | `AuthModel.signIn` |
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

## Planned: App Attest (later PR)

Goal: the API serves only genuine copies of the app on real Apple devices (DeviceCheck App Attest). The endpoints come
from the API thread's `openapi.yaml` (draft); names below are the proposal.

1. First launch: `DCAppAttestService.shared.isSupported` (not on the simulator: the API accepts a debug bypass only
   on staging). `generateKey()` → key ID, kept in the Keychain (this device only).
2. `POST /v1/attest/challenge` → one-time challenge (short TTL).
3. `attestKey(keyID, clientDataHash: SHA256(challenge))` → attestation object.
   `POST /v1/attest/register {keyId, attestation, challenge}`: the API verifies the Apple certificate chain, the app
   ID (`9572LYGZ7S.com.zapacit.cuzaai`), the counter, and stores the public key with the parent.
4. Sensitive calls (sign-in, adding a kid, key upload, family connections) carry an assertion:
   `generateAssertion(keyID, clientDataHash: SHA256(request body + challenge))` in an `X-App-Assertion` header; the API
   checks the signature and that the counter only goes up.
5. Failures: a new key on reinstall; the API rate-limits and reports devices that fail attestation, but chat content
   stays end-to-end encrypted either way (App Attest protects the API, not the encryption).

Tests: the attest client against a mocked API (as `HTTPAuthAPITests`), a fake `DCAppAttestService` behind a protocol.

## Planned: key verification (later PR)

- **Safety numbers** from libsignal (`Fingerprint` / `NumericFingerprint` and `ScannableFingerprint`): each pair of
  parents can compare a 60-digit number or scan each other's QR code in person. A verified contact gets a visible
  "verified" mark.
- **Key-change warning:** when a contact's identity key changes (new phone, reinstall), the chat shows a clear system
  message and, for a verified contact, blocks sending until the parent acknowledges it (re-verify or accept).
- Kids' phones are verified by the parent's QR pairing itself (the QR carries the kid phone's identity key
  fingerprint), so no extra step for kids.

Tests: unit tests on the verification state machine; a UI test for the key-change banner with a stubbed key store.
