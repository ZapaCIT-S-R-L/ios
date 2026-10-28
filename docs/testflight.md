# TestFlight uploads

`.github/workflows/testflight.yml` archives a signed Release build and uploads it to TestFlight on every merge to
`main`, and when started by hand from `main` (Actions → testflight → Run workflow). Until the App Store Connect API
key is in the `testflight` environment, the job skips with a notice.

Nobody but Stefan handles the key. It goes from App Store Connect straight into the GitHub environment secret.

## One-time setup (Stefan)

1. **App record.** App Store Connect → Apps → + → New App: platform iOS, name ZapaKid, primary language Romanian,
   bundle ID `ro.zapakid.app` (registered in the Developer portal), SKU `zapakid-ios`, user access full.
2. **API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → +.
   Name `github-testflight`, access **Admin**. Xcode's automatic signing in CI creates the cloud-managed distribution
   certificate, and Apple allows that only for Admin keys. Download the `.p8` once; note the **Key ID** and the
   **Issuer ID** shown above the list.
3. **Environment.** GitHub → ZapaCIT-S-R-L/ios → Settings → Environments → New environment `testflight`:
   - Deployment branches and tags: **Selected branches**, add `main`.
   - Required reviewers: `stefan-zpc` (each upload waits for your approval), optional but recommended.
   - Environment secrets (no repository secrets):
     - `ASC_KEY_ID`: the Key ID
     - `ASC_ISSUER_ID`: the Issuer ID
     - `ASC_KEY_P8`: the key file as base64, from a terminal: `base64 -i AuthKey_<KeyID>.p8 | pbcopy`, then paste
   - Then delete the downloaded `.p8` from the Mac (or keep it only in your password manager).
4. **First upload.** Actions → testflight → Run workflow (branch `main`). The build shows up in App Store Connect →
   TestFlight after processing (about 10–30 minutes). Add yourself as an internal tester there.

## Rotating or revoking

Revoke the key in App Store Connect (Integrations → the key → Revoke), create a new one, and replace the three
secrets. A revoked key stops uploads at once; nothing else uses it.

## Notes

- Build numbers are the workflow's run number, so every upload is higher than the last. The version (`1.0.0`) comes
  from `project.yml`.
- App Attest uses the production environment in TestFlight and App Store builds whatever the entitlement says.
- The workflow uses only the three environment secrets, pins every action by commit SHA, writes the key with
  `umask 077` and deletes it at the end of the job.
