# Contributing

Thanks for helping. Issues and pull requests are welcome.

- **Small pull requests**, one change each, with a clear description.
- **Tests first:** add or change the test that shows the change (`ZapaKidTests/` for unit tests, `ZapaKidUITests/`
  for UI tests), see it fail, then write the code. `scripts/test.sh` must pass.
- **Accessibility:** every screen works with Dynamic Type up to the largest size and has VoiceOver labels.
- **Style:** `swiftformat .` and `swiftlint` before you push (CI runs both).
- **No credentials** in code, commits or issues. CI scans every pull request.
- **Security issues** go through [SECURITY.md](SECURITY.md), never a public issue.

## Bumping libsignal (by hand)

libsignal comes from Signal's CocoaPod (`Podfile`), the way Signal-iOS uses it. Dependabot can't update CocoaPods, so
check for a new release when you start work and at least every two weeks (`gh api repos/signalapp/libsignal/releases/latest`).
Never go back to an older version.

1. In `Podfile`, set `tag:` to the new release (`vX.Y.Z`) and `LIBSIGNAL_FFI_PREBUILD_CHECKSUM` to the SHA-256 in that
   release's asset `libsignal-client-ios-build-vX.Y.Z.tar.gz.sha256`
   (`gh release download vX.Y.Z -R signalapp/libsignal -p '*.tar.gz.sha256' -O -`). Update the comment above it.
2. `xcodegen generate && pod install`, and commit `Podfile` and `Podfile.lock` (never `Pods/`).
3. Read the release notes for breaking API changes, run `scripts/ci-local.sh`, and open a PR titled
   "libsignal vX.Y.Z" with the release link.

`scripts/osv-scan.sh` scans libsignal's `Cargo.lock` at the pinned tag: a HIGH or CRITICAL finding fails CI, and the
fix is a bump.

## Contributor License Agreement

This project is licensed under the [AGPL-3.0](LICENSE). Before we can merge your first pull request, you sign the
[ZapaKid Contributor License Agreement](CLA.md): add a row with your GitHub username to
[CLA-SIGNATURES.md](CLA-SIGNATURES.md) in that pull request. The `cla` check confirms it. You keep the copyright in
your contribution, and ZapaCIT SRL can distribute it, including through the app stores.
