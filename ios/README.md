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
  Models/        — mock data (until Supabase + HealthKit are wired)
  Resources/Fonts/
```

Status: **app shell** — five screens render from mock data and the real pace engine.
Next: Auth + HealthKit ingest, then wire screens to live data.
