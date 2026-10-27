# ZapaKid for iOS

End-to-end encrypted family chat (text, photos, voice) between parents and their kids, and between connected
families. One app with a parent mode and a kid mode. ZapaKid (the company and its servers) can never read the chats.

- Swift 6 + SwiftUI, iOS 17 or later. The Xcode project is generated from `project.yml` with
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) and not committed.
- `ZapaKid/`: the app (screens). libsignal (Signal's `LibSignalClient` CocoaPod, `Podfile`) does all chat
  cryptography. `ZapaKidKit/`: the logic without UI (API client, session), a local
  Swift package. `ZapaKidTests/`: unit tests (Swift Testing). `ZapaKidUITests/`: UI tests (XCUITest).
- API: `https://api-staging.zapakid.ro` (Cloudflare Workers), see the `api` repository.

## Build and test

```sh
brew install xcodegen cocoapods swiftformat swiftlint
xcodegen generate && pod install && open ZapaKid.xcworkspace   # Xcode
scripts/ci-local.sh                           # the whole CI suite locally; run before every push
swiftformat . && swiftlint --strict           # style, as CI does
npm test                                      # the CLA and release-tag scripts (Node 24, see .nvmrc)
```

`scripts/test.sh` picks an iPhone simulator on the newest iOS runtime; set `SIM_UDID` to use a specific one.
Simulator builds are signed ad hoc, so no Apple account is needed. Never run tests on a physical phone.

## How changes ship

1. Run `scripts/ci-local.sh` and push only when it is green (CI runs only the unit tests on PRs). Open a pull request. CI (`.github/workflows/ci.yml`) builds the app, runs the unit tests on a simulator (UI tests too on main),
   lints, scans the dependencies (OSV-Scanner) and the whole history (gitleaks), and checks the CLA. CodeQL scans the
   Swift code and the workflows.
2. A maintainer reviews and merges it.
3. The merge to `main` tags the commit `vMAJOR.MINOR.PATCH` and publishes a GitHub release with an SBOM
   (`.github/workflows/release.yml`): no label = patch, label `minor` = a large feature, label `major` = a breaking
   change. The same merge uploads a signed build to TestFlight (`.github/workflows/testflight.yml`, environment
   `testflight`; setup in [docs/testflight.md](docs/testflight.md)).

## License

[AGPL-3.0](LICENSE). Contributions need the CLA, see [CONTRIBUTING.md](CONTRIBUTING.md).
Security issues: see [SECURITY.md](SECURITY.md). How the app protects chats and accounts: [docs/security.md](docs/security.md).
