---
title: "Tempo: App Store listing"
project: Tempo
type: reference
status: draft
created: 2026-11-03
tags: [tempo, app-store]
---

# Tempo: App Store listing

Everything App Store Connect asks for, ready to paste. Assets are in `appstore/out/`, and
[appstore/README.md](../appstore/README.md) explains how to re-shoot them.

Copy rules this draft follows, from the [[decision-log]] and [[prd-02-drift-detector]]:

- **No Drift Detector claims.** Its engine is merged, but the hero chart hasn't shipped. "On
  track" here means what the app shows today: projected finish against your goal.
- **No privacy slogans.** The data section only repeats flows the privacy policy maps to code.
- **No injury or medical claims.**
- **No competitor names.** Strava and Runna appear nowhere. Garmin and Coros appear once, as
  sources that write to Apple Health. Apple doesn't allow other company names in keywords.

## Must clear before you submit

| # | What | Why it matters | Who |
|---|---|---|---|
| 1 | **Ask permission before data goes to Anthropic.** The app has no such screen today. | Guideline 5.1.2(i): you must "clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission". This is the likeliest rejection. | Needs a build |
| 2 | **Privacy policy URL is live.** It returns 404 until PR #250 merges. | Required field. Tempo also reads HealthKit. | Merge |
| 3 | **Fix the public pages.** `privacy.html` and `index.html` say "small TestFlight beta", and `index.html` has no contact details. | The support URL must lead to real contact information. | Small PR |
| 4 | **Delete from inside the app.** Today deletion means emailing you. | Guideline 5.1.1(v) requires in-app deletion if an app "supports account creation". Anonymous accounts are a grey area, so a reviewer could go either way. | Your call |
| 5 | **Limit coach usage per user.** `coach` has no rate limit, and anyone can get an anonymous account. | Not a review issue. A public listing makes this an open door to your Anthropic bill. | Needs a build |
| 6 | **Version number.** `MARKETING_VERSION` is `0.1.0`. | Legal, but it would show publicly. Suggest `1.0.0`. | One line |

## App information

| Field | Value | Notes |
|---|---|---|
| Name (30) | `Tempo: AI Running Coach` | Check against your existing record. "Tempo: Home Workout & Fitness" (CoreTech Fitness) is already in Health & Fitness, so a same-category trademark complaint is possible. |
| Subtitle (30) | `Am I on track for race day?` | |
| Primary category | Health & Fitness | |
| Secondary category | Sports | Optional. |
| Bundle ID | `studio.delight.tempo` | Already registered. |
| SKU | `tempo` | |
| Content rights | Does not contain third-party content | |
| Price | Free | Matches the 2026-10-15 decision. |
| Devices | iPhone only | `TARGETED_DEVICE_FAMILY` is `1`, so no iPad assets are needed. |
| Minimum OS | iOS 26.0 | |
| Export compliance | Already answered | `ITSAppUsesNonExemptEncryption` is false in `project.yml`. |

## Version information

### Promotional text (170)

```text
Tempo reads your runs from Apple Health, builds a plan around them, and tells you plainly whether you're on track for race day, from the mile to the marathon.
```

### Keywords (100 bytes)

```text
marathon,half,5km,10k,training,plan,pace,runner,run,tracker,gps,heart rate,zones,splits,workout
```

### Description (4,000)

```text
Am I on track? Tempo answers that question for your next race, starting from the running you've already done.

Tempo reads your history from Apple Health, so it works with Apple Watch, Garmin, Coros and other apps that write runs to Health. Keep your watch and your routine. Tempo adds the plan, the coach and a straight answer.

A PLAN BUILT FROM YOUR REAL RUNNING
• Pick your race, from the mile to the marathon, and what you want from it
• Tempo assesses your recent training before it decides the shape of the block
• Quality days come with reps and paces, easy days with a distance and an effort
• Want five days instead of six, or a Saturday long run? Ask the coach, confirm the change, and the plan regenerates from this week
• Missed a hard session? It moves to a later easy day and tells you why

SEE WHERE YOU STAND
• Projected finish against your goal, recalculated as your runs come in
• Fitness, fatigue and readiness from your own training load
• A pre-run check-in on hard days, because how you feel counts

A COACH THAT KNOWS YOUR TRAINING
• Open any run and get an honest read of it
• Ask anything about your training, and hear why a session is on the plan
• Conversations are saved with a title and a recap, so last week's decision is easy to find
• A calm voice, with no hype and no guilt

EVERY RUN, IN DETAIL
• Route map colored by pace
• Scrubbable pace and heart rate chart, elevation, heart rate zones and mile splits
• Years of running on one screen, with your records and best efforts
• A journal for effort, feel, notes, photos and shoes

RECORD RUNS IN TEMPO TOO
• GPS and treadmill runs, with auto-pause and spoken split cues
• Live pace on the Lock Screen and in the Dynamic Island
• Race mode files the run as your goal race
• Recorded runs save to Apple Health

ALSO
• Home Screen and Lock Screen widgets
• Miles or kilometers
• Light and dark themes

No sign-up, and no paywall.

YOUR DATA
Tempo doesn't ask for your name, email or a password. With your permission it reads workouts, heart rate, distance, steps, active energy and workout routes from Apple Health. GPS routes and raw health samples stay on your phone. Run summaries, your plan, your journal and your coach conversations are stored on Tempo's server so the coach can work. To write replies, the coach sends your message and a summary of your training to Anthropic's Claude. Tempo has no ads and no third-party tracking. The privacy policy has the details.

A NOTE ON HEALTH
Tempo is a training tool, not a medical device. It doesn't diagnose or treat anything, and its projections are estimates. Check with a doctor before starting or changing a training program, and about any pain or injury.
```

### URLs and legal

| Field | Value |
|---|---|
| Support URL | `https://magicwilliams.github.io/kill-strava/` (live after #250, needs contact details: item 3) |
| Marketing URL | Leave blank for now |
| Privacy Policy URL | `https://magicwilliams.github.io/kill-strava/privacy.html` (live after #250) |
| Copyright | `2026 David Latimore II` (Apple adds the ©. Use your seller name if it's Delight Studio.) |
| Version | `1.0.0` (item 6) |
| What's New | Not available on a first version |

## Age rating

Likely result: **13+**, which matches the policy's "not intended for children under 13". Confirm
against the live questionnaire, which may add questions.

| Question | Answer | Why |
|---|---|---|
| Health or Wellness Topics | Yes | Exercise recommendations are the product. |
| Medical or Treatment Information | Infrequent | The coach responds when someone reports pain or injury, without diagnosing it. This is the answer that sets 13+. |
| Messaging and Chat | No | Apple defines it as users talking to each other. The coach isn't a user. |
| User-Generated Content | No | Photos and notes are private, not distributed. |
| Social Media, Advertising, Unrestricted Web, Contests, Gambling | No | |
| Parental Controls, Age Assurance | No | |
| All violence, sexual, mature, horror, substance categories | None | |
| Made for Kids | No | |

## App Privacy

**Tracking: No.** Every type below is linked to the anonymous user ID, and the only purpose is
**App Functionality**.

| Apple category | Data type | What it is in Tempo |
|---|---|---|
| Health & Fitness | Health | Average and per-split heart rate, effort ratings, max HR, injury notes |
| Health & Fitness | Fitness | Run summaries, splits, training load, plan, goals |
| Identifiers | User ID | The random anonymous account ID |
| User Content | Photos or Videos | A photo you attach to a run |
| User Content | Other User Content | Coach conversations, journal notes, run titles, shoes |
| Diagnostics | Other Diagnostic Data | `app_events`: errors and retries, with app and iOS version |
| Other Data | Other Data Types | Birthdate, if given, for heart rate zones |

**Not collected, because it never leaves the device:** Precise Location. Routes stay in Apple
Health. Recheck this if routes ever reach the server. Apple counts data sent off the device,
including to processors like Supabase and Anthropic.

## App Review information

| Field | Value |
|---|---|
| Sign-in required | No. Leave the demo account blank. |
| Contact | David Latimore II, `david@delight.studio`, **phone needed** (`+1...`) |

### Notes (4,000 bytes)

```text
SIGN-IN
None. Tempo creates an anonymous account on first launch.

TO TEST
1. Open the app and continue past Welcome.
2. On "Connect your runs", allow Apple Health. A review device with no runs shows "No runs found yet". Continue anyway: the coach asks about your recent running instead.
3. Answer the coach's setup questions. It proposes a goal and a plan, and you confirm it.
4. Today shows the session. Plan, Progress, Coach and You are the other tabs.
5. To test recording, start a run from Today. It saves to Apple Health when finished.
With an empty Health store, the charts and history stay sparse. That is expected.

HEALTHKIT
Tempo reads workouts, heart rate, distance, steps, active energy and workout routes to show runs and build the plan. It writes workouts, routes, distance and active energy only for runs recorded in Tempo, and it asks for write access at the first recorded run. Health data is not used for advertising.

THIRD-PARTY AI
The coach is powered by Anthropic's Claude API. Coach messages and a summary of the runner's training are sent to it to write replies. [UPDATE WHEN THE CONSENT SCREEN SHIPS: describe where it appears.] Routes and raw samples are not sent.

BACKGROUND MODES
location: keeps measuring distance and pace when the phone locks during a run the user started. Location access is "When In Use" and stops when the run ends.
audio: speaks split cues while the phone is locked in a pocket.

HEALTH
Tempo is a training tool. It makes no diagnostic or treatment claims, and it tells users to check with a doctor.
```

## Regional

**EU trader status (Digital Services Act):** Apple asks for this before EU distribution. Declaring
as a trader publishes your address, phone and email on the listing. Your options are to answer
honestly as a non-trader if that fits, or to leave EU storefronts out of the first release. It's
your call, and worth a quick legal check given that Delight Studio is a business.

## Header and Search Results

Optional, separate from screenshots, and shown on iOS and iPadOS 27 and later. Without a search
asset, the App Store falls back to previews and screenshots.

| Placement | File | Spec |
|---|---|---|
| Product page header | `appstore/out/header/tempo-header-3840x1646.png` | 21:9, 3840 × 1646 |
| Search results | `appstore/out/header/tempo-search-3840x2560.png` | 3:2, up to 3840 × 2560 |
| Universal (either) | `appstore/out/header/tempo-universal-5244x2950.png` | 16:9, 5244 × 2950, PNG only |

Apple prohibits prices, URLs, unverifiable claims, and references to other platforms in these. It
reviews each asset on its own, so they can change without a new app version. Apple's page publishes
no numeric safe area, so key content sits near the center: **check both crops with Preview in App
Store Connect before submitting.**

## App Previews and Screenshots

| Asset | Folder | Spec |
|---|---|---|
| iPhone 6.9" | `appstore/out/screenshots/6.9/` | 1320 × 2868 PNG, no alpha |
| iPhone 6.1" (the required size) | `appstore/out/screenshots/6.1/` | 1206 × 2622 PNG, no alpha |
| App preview | `appstore/out/preview/tempo-preview-886x1920.mp4` | 886 × 1920, 30 fps, H.264, stereo AAC, 15–30 s |

Upload in filename order. The first three are what can appear in search results.

The preview's first frames lead with Progress, and Apple's default poster frame (5 seconds) lands on
the route map. It carries a silent stereo track because Apple requires audio.

### What's in them

- **A fictional runner, not you.** Sam's 955 workouts were generated and went through the real
  HealthKit ingest on a local stack. The projection, splits, load and records are Tempo's own output.
- **Hand-written coach text.** The coach doesn't run locally, so the conversation and run reads were
  written to match its voice and checked against the computed numbers. The proposed-change card is
  the real UI, showing a seeded proposal.
- **Harbor City Marathon** is invented. The route uses real Central Park map tiles.
- **Dark theme only.** The app also has a light theme, which isn't shown.

### Noticed while shooting

None of these block the assets, and none are fixed here.

- **Readiness can contradict the plan.** With slightly more load, Today reads "Easy miles serve you
  best today" directly above a scheduled tempo.
- **Content scrolls under the status bar** on Coach, Run Detail and History, with no background, so
  text collides with the clock.
- **Run Detail covers the Apple Maps attribution.** The save screen shows it. MapKit's terms expect
  it to stay visible.
- **Onboarding still says** "No in-app recording needed", and its tagline is "Marathon coaching",
  though Tempo now records runs and covers every distance.
