# TestFlight uploads

`.github/workflows/testflight.yml` archives a signed Release build and uploads it to TestFlight on every merge to
`main`, and when started by hand from `main` (Actions → testflight → Run workflow). Until all six secrets below are
in the `testflight` environment, the job skips with a notice that names the missing ones.

Signing is manual (Stefan's choice, 2026-10-27): an **App Manager** API key only uploads; an **Apple Distribution**
certificate and an **App Store** provisioning profile sign the build. On the runner the certificate lives in a
temporary keychain with a random password, and the key, certificate, keychain and profile are deleted at the end of
every run.

Only Stefan handles these files. They go from Apple straight into GitHub environment secrets, through `gh secret set`
reading standard input, so no value lands in the shell history or on screen.

## One-time setup (Stefan)

Run the commands in Terminal on your Mac, signed in to `gh` as `stefan-zpc`. Keep the downloads in one folder, for
example `~/Desktop/zapakid-signing`, and delete it at the end (step 7).

1. **App record.** App Store Connect → Apps → + → New App: platform iOS, name ZapaKid, primary language Romanian,
   bundle ID `ro.zapakid.app`, SKU `zapakid-ios`, user access full.

2. **API key (App Manager).** App Store Connect → Users and Access → Integrations → App Store Connect API →
   Team Keys → +. Name `github-testflight`, access **App Manager**. Download `AuthKey_<KeyID>.p8` (only possible
   once). Note the **Key ID** and the **Issuer ID** shown above the list.

3. **Distribution certificate.**
   - Keychain Access → Keychain Access menu → Certificate Assistant → Request a Certificate From a Certificate
     Authority: your email, common name `ZapaKid Distribution`, "Saved to disk". This makes
     `CertificateSigningRequest.certSigningRequest`.
   - developer.apple.com → Certificates, IDs & Profiles → Certificates → + → **Apple Distribution** → upload the
     request → Download `distribution.cer` and double-click it (it joins the private key in your login keychain).
   - Keychain Access → My Certificates → "Apple Distribution: <team name> (9572LYGZ7S)" → right-click → Export →
     format Personal Information Exchange (.p12) → `zapakid-distribution.p12`, with a **new strong password**
     (generate it in your password manager and keep it there).

4. **Provisioning profile.** developer.apple.com → Profiles → + → Distribution → **App Store Connect** → App ID
   `ro.zapakid.app` → the certificate from step 3 → name `ZapaKid App Store` → Generate → Download
   `ZapaKid_App_Store.mobileprovision`.

5. **Environment.** GitHub → ZapaCIT-S-R-L/ios → Settings → Environments → New environment `testflight`:
   - Deployment branches and tags: **Selected branches** → add `main`.
   - Required reviewers: `stefan-zpc` (every upload waits for your OK; recommended).

6. **Secrets** (environment secrets, not repository secrets). In the download folder:

   ```sh
   cd ~/Desktop/zapakid-signing
   R=ZapaCIT-S-R-L/ios
   gh secret set ASC_KEY_ID --env testflight --repo $R             # gh asks for the value (hidden): paste the Key ID
   gh secret set ASC_ISSUER_ID --env testflight --repo $R          # paste the Issuer ID
   base64 -i AuthKey_*.p8 | gh secret set ASC_KEY_P8 --env testflight --repo $R
   base64 -i zapakid-distribution.p12 | gh secret set DIST_CERT_P12 --env testflight --repo $R
   gh secret set DIST_CERT_PASSWORD --env testflight --repo $R     # paste the .p12 password
   base64 -i ZapaKid_App_Store.mobileprovision | gh secret set PROVISIONING_PROFILE --env testflight --repo $R
   gh secret list --env testflight --repo $R                       # shows the six names, never the values
   ```

7. **Clean up the Mac.** Move the `.p8` and `.p12` into your password manager if you want a copy, then
   `rm -rf ~/Desktop/zapakid-signing`. The certificate stays in your login keychain; that's fine.

8. **First upload.** Actions → testflight → Run workflow (branch `main`), approve it. The build shows in App Store
   Connect → TestFlight after processing (about 10–30 minutes). Add yourself as an internal tester there.

## Rotation

| What | When | How |
| --- | --- | --- |
| API key | When someone who had it leaves, or yearly | App Store Connect → Integrations → the key → Revoke; make a new one (step 2); replace `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` |
| Distribution certificate | Expires after 1 year (Apple emails before) | Steps 3, 4 and 6 for `DIST_CERT_P12`, `DIST_CERT_PASSWORD`, `PROVISIONING_PROFILE`; then revoke the old certificate on developer.apple.com |
| Profile | Expires with the certificate, or when the App ID's capabilities change | Step 4, then `PROVISIONING_PROFILE` |
| After a leak | At once | Revoke the key and the certificate first, then make new ones; builds already on TestFlight stay valid |

## Notes

- Build numbers are the workflow's run number, so every upload is higher than the last. The version (`1.0.0`) comes
  from `project.yml`.
- Only the app target reads the `ZK_*` signing settings (`project.yml`, Release); local builds still sign
  automatically.
- App Attest uses the production environment in TestFlight and App Store builds whatever the entitlement says.
- The workflow uses only these six environment secrets, pins every action by commit SHA, writes files with
  `umask 077`, never prints a secret, and deletes everything in an `always()` step.
