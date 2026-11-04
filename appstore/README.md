# App Store assets

The copy and the App Store Connect field-by-field answers are in
[docs/app-store-listing.md](../docs/app-store-listing.md). This folder is how the images are made.

## The rule

**Screenshots never show David's data.** The repo is public, and the database behind his phone is
his real training history. Everything here comes from a fictional runner ("Sam") on a throwaway
local Supabase stack and in a simulator's own Apple Health. Nothing touches staging or production.

The numbers are real output, though. The workouts go in through HealthKit and the app's normal
ingest, so pace, splits, load, records and the projection all come from Tempo's own code. What the
coach function would have written (run reads, conversations) is seeded by hand in
`tools/seed_coach.sql`, because the coach doesn't run locally. If a figure in that file stops
matching what the app computes, change the file.

## Re-shooting

1. Make a scratch worktree of `main`, and copy `tools/DemoSeeder.swift` into
   `ios/Tempo/Services/`.
2. In that worktree only, never in a commit:
   - `SupabaseConfig.swift`: point the staging URL and key at `supabase status`.
   - `TempoApp.swift`: `.task { await DemoSeeder.run(); if !DemoSeeder.requested { await runs.start() } }`
   - `project.yml`: add `NSAppTransportSecurity: {NSAllowsArbitraryLoads: true, NSAllowsLocalNetworking: true}`
     to the app's Info.plist properties, then `xcodegen generate`.
3. Start the stack from a scratch `supabase init`, with `enable_anonymous_sign_ins = true` and the
   migrations copied in, renumbered so their prefixes are unique (`0002` and `0013` repeat):
   - Leave out `0013_purge_ci_anonymous_users.sql`. Its guard refuses any database but production.
   - Then `grant all on all tables in schema public to anon, authenticated, service_role;` because
     the local image doesn't grant these by default.
   - If `supabase start` hangs on pulls, `docker pull` the images first.
4. Build with the project's normal signing, using the `iPhone 17 Pro Max` simulator. Other flags
   strip the HealthKit entitlement. Launch once with no arguments to create the user, then with
   `-seedHealth`, and allow Health access. It writes 955 workouts in under a minute.
5. Load the runner: `python3 tools/seed_plan.py <user id> | psql`. Launch normally so the app
   ingests the workouts, then load `tools/seed_coach.sql`.
6. Set the status bar: `xcrun simctl status_bar booted override --time 9:41 --batteryState discharging --batteryLevel 100 --cellularBars 4 --wifiBars 3`.
7. Capture each screen named in `tools/compose.py` with `xcrun simctl io booted screenshot`.

## Rendering

```bash
python3 tools/render_header.py /path/to/raw/captures
```

```bash
python3 tools/compose.py /path/to/raw/captures
```

Each script checks exact pixel size and the absence of alpha after it writes. The output in `out/`
is gitignored, because it's large and can be regenerated.
