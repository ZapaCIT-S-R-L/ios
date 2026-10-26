# Contributing

Thanks for helping. Issues and pull requests are welcome.

- **Small pull requests**, one change each, with a clear description.
- **Tests first:** add or change the test that shows the change (`ZapaKidTests/` for unit tests, `ZapaKidUITests/`
  for UI tests), see it fail, then write the code. `scripts/test.sh` must pass.
- **Accessibility:** every screen works with Dynamic Type up to the largest size and has VoiceOver labels.
- **Style:** `swiftformat .` and `swiftlint` before you push (CI runs both).
- **No credentials** in code, commits or issues. CI scans every pull request.
- **Security issues** go through [SECURITY.md](SECURITY.md), never a public issue.

## Contributor License Agreement

This project is licensed under the [AGPL-3.0](LICENSE). Before we can merge your first pull request, you sign the
[ZapaKid Contributor License Agreement](CLA.md): add a row with your GitHub username to
[CLA-SIGNATURES.md](CLA-SIGNATURES.md) in that pull request. The `cla` check confirms it. You keep the copyright in
your contribution, and ZapaCIT SRL can distribute it, including through the app stores.
