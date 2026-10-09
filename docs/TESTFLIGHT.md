# TestFlight — how builds reach the phone

Decided in #59 (option B). Every green `main` → `.github/workflows/testflight.yml` → a
TestFlight build → a notification on David's phone. No Xcode, no cable, no remembering.

Nothing in this file can be done by an agent: it all needs David's Apple account, and the
last step needs his phone.

## One-time setup (about 30 minutes)

### 1. Team ID
developer.apple.com → Account → **Membership details** → copy the **Team ID**.

For David it is `2P8QGJVNJ7`: the same ID Xcode's Personal Team used, because the paid
membership kept it. That's why step 7 is normally a no-op.

### 2. Register the bundle ID
developer.apple.com → Certificates, IDs & Profiles → **Identifiers** → `+` → App IDs → App.
- Bundle ID (explicit): `studio.delight.tempo`
- Capabilities: tick **HealthKit**

If Apple says the identifier is unavailable, the free team is still holding it. Tell the EM;
the fallback is changing `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`, which is a
one-line PR.

### 3. Create the app record
appstoreconnect.apple.com → **Apps** → `+` → New App.
- Platform iOS, bundle ID `studio.delight.tempo`, SKU `tempo`
- Name must be unique across the whole App Store, and plain "Tempo" is almost certainly taken. Anything
  works ("Tempo Marathon Coach"); only TestFlight sees it. The name on the home screen still
  comes from `CFBundleDisplayName` ("Tempo").

### 4. API key for CI
App Store Connect → **Users and Access** → **Integrations** → App Store Connect API →
Team Keys → `+`.
- Access: **Admin**. Lower roles can upload but can't create the distribution certificate,
  which cloud-managed signing needs on its first run.
- Note the **Key ID** and the **Issuer ID** (shown above the keys table).
- Download the `.p8`. Apple lets you download it **once**.

### 5. Hand it to GitHub
From the repo root on the Mac. These go straight from your disk into GitHub's encrypted store,
and nothing lands in the repo or in chat:

```bash
gh secret set ASC_KEY_ID --body "XXXXXXXXXX"
```
```bash
gh secret set ASC_ISSUER_ID --body "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```
```bash
gh secret set ASC_KEY_P8 < ~/Downloads/AuthKey_XXXXXXXXXX.p8
```
```bash
gh variable set APPLE_TEAM_ID --body "YOURTEAMID"
```

Then move the `.p8` somewhere safe (a password manager) and delete it from Downloads.

### 6. First build
GitHub → Actions → **TestFlight** → Run workflow (on `main`). Takes about 15 minutes, plus
5–15 minutes of Apple processing. Then in App Store Connect → your app → **TestFlight** →
Internal Testing → `+` group → add yourself. Install the **TestFlight** app on the phone and
accept the invite.

From then on each merge to `main` that passes CI ships on its own, and the build number is the
Actions run number.

### 7. Your history carries over on its own
The login lives in the Keychain under *team ID + bundle ID*. Both are unchanged
(`2P8QGJVNJ7`, `studio.delight.tempo`), so the TestFlight build reads the same anonymous
session the Xcode builds did, and you open straight into your runs, plan and coach history.

**Only if the app opens empty** (it would mean the session didn't survive, e.g. the team ID
ever changes): your data isn't gone, it still belongs to the old user. Run
`supabase/ops/carry_over_athlete.sql` in the Supabase SQL editor with the new user's id
(newest row in Authentication → Users). Run it as-is for the dry-run counts, then uncomment
step 2 and run again.

## When it breaks

- **Workflow warns "TestFlight not configured"**: a secret or the variable is missing (step 5).
- **"No profiles for 'studio.delight.tempo' were found"**: the API key isn't Admin (step 4),
  or the App ID lacks HealthKit (step 2).
- **Upload rejected for SDK version**: Apple raised the minimum Xcode. Bump `runs-on` to the
  newest macOS runner.
- **Build is "Missing Compliance"**: `ITSAppUsesNonExemptEncryption` fell out of
  `ios/project.yml`.
