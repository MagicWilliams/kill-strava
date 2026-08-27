# Tempo — iOS

SwiftUI app. The Xcode project is generated from `project.yml` via **XcodeGen** so it
stays reproducible and merge-friendly (no `.xcodeproj` in git).

## Build
```bash
brew install xcodegen        # once
cd ios
xcodegen generate            # writes Tempo.xcodeproj
open Tempo.xcodeproj
```
Then in Xcode → Signing & Capabilities, set your **Development Team**, and run on a
real device (HealthKit isn't available in the simulator).

### Regenerate after the working tree moves
`project.yml` declares sources as a *directory*, so XcodeGen bakes the concrete file list
into `Tempo.xcodeproj` when you generate. The `.xcodeproj` is gitignored, so it does not
follow the working tree. Switch to a branch that predates a file and Xcode still builds
against the old list:

```
Build input file cannot be found: '.../ios/Tempo/Services/LaunchGate.swift'
```

That is a stale project, not a missing file. Fix it with `cd ios && xcodegen generate`.

To stop it recurring, opt in once to the repo's hooks — they regenerate after any
checkout, pull, or rebase that moves a file under `ios/`:

```bash
git config core.hooksPath .githooks   # once, per clone
```

They no-op when `ios/` didn't change, and print a hint instead of failing if `xcodegen`
isn't installed.

## Fonts
Drop these `.ttf` files into `Tempo/Resources/Fonts/` (all free):
- **Space Grotesk** — `SpaceGrotesk-Bold.ttf`
- **Inter** — `Inter-Regular.ttf`, `Inter-Medium.ttf`, `Inter-SemiBold.ttf`, `Inter-Bold.ttf`
- **Roboto Mono** — `RobotoMono-Medium.ttf`

The UI falls back to system fonts until they're added, so it builds without them.

## Structure
```
Tempo/
  App/           — entry point + root tab navigation
  DesignSystem/  — tokens (Tokens.swift) + reusable components (Components.swift)
  Screens/       — Today, Plan, Progress, Coach, You
  Engine/        — deterministic training math (TrainingPaces.swift)
  Services/      — Supabase client + HealthKit ingest
  Models/        — Codable models (+ Mock data until live data is wired)
  Resources/Fonts/
```

The `Supabase` SPM package is declared in `project.yml`; `xcodegen generate` resolves it.
Supabase project `Tempo` (`lpgdhqqroyqdrjsrlodo`) is provisioned with the schema + RLS applied.

Status: **app shell + data layer scaffold** — five screens render from mock data and the
real pace engine; Supabase client, models, and HealthKit ingest are in place.
Next: **Sign in with Apple** (so ingested runs get a `user_id`), then swap screens to live data.
