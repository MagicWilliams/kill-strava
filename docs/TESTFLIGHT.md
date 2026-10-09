# TestFlight — how builds reach the phone

Decided in #59 (option B). Every green `main` → `.github/workflows/testflight.yml` → a
TestFlight build → a notification on David's phone. No Xcode, no cable, no remembering.

Nothing in this file can be done by an agent: it all needs David's Apple account, and the
last step needs his phone.

## One-time setup (about 30 minutes)

### 1. Team ID
developer.apple.com → Account → **Membership details** → copy the **Team ID**.

It will not be `2P8QGJVNJ7` — that is Xcode's free Personal Team, which is what every build
so far has been signed with. That difference is why step 7 exists.

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

### 7. Carry your history across (once)
The TestFlight build is signed by a different team than the Xcode build, so it can't read the
old Keychain login. On first open it becomes a **new, empty anonymous user**. Your runs, plan,
corrections and coach history are not lost; they still belong to the old user.

1. Delete the Xcode-installed Tempo if TestFlight refuses to install over it.
2. Open the TestFlight build once. Grant Health. Let it sync, then close it.
3. Run `supabase/ops/carry_over_athlete.sql` in the Supabase SQL editor (Tempo project):
   paste the new user's id (newest row in Authentication → Users), run it as-is for the dry
   run, check the counts, then uncomment step 2 and run again.
4. Force-quit and reopen the app. Your plan and history should be back.

## When it breaks

- **Workflow warns "TestFlight not configured"**: a secret or the variable is missing (step 5).
- **"No profiles for 'studio.delight.tempo' were found"**: the API key isn't Admin (step 4),
  or the App ID lacks HealthKit (step 2).
- **"No profiles for 'studio.delight.tempo.widgets'" or an App Groups provisioning error**
  (first run after the widgets, #76): the API key didn't register the extension or the group
  itself. developer.apple.com → Identifiers → `+` → **App Groups** → `group.studio.delight.tempo`.
  Then `+` → App IDs → App → `studio.delight.tempo.widgets` with **App Groups** ticked and the
  group assigned, and add **App Groups** (same group) to `studio.delight.tempo` too. Re-run
  the workflow.
- **Upload rejected for SDK version**: Apple raised the minimum Xcode. Bump `runs-on` to the
  newest macOS runner.
- **Build is "Missing Compliance"**: `ITSAppUsesNonExemptEncryption` fell out of
  `ios/project.yml`.
