---
tags: [tempo, decision-log]
---

# Decision log

Newest first. One entry per session that ships features or makes a product decision.

## 2026-11-05: The rulebook catches up with the public TestFlight

### Decisions
- **Tempo is no longer a beta of one.** The public TestFlight opened today, so `CLAUDE.md` and the Scout, Builder and EM definitions stop assuming David is the only user. Hard limits 1 and 2 are unchanged. Limit 3 now names testers' data, and it corrects "no staging copy": staging exists, for simulators and CI, but it holds no copy of production data.
- **Production reads and cleanups state whose rows they cover.** Accounts are anonymous, so a row never says whose it is.
- **Telemetry triage separates David from other users,** with events, distinct users and app version. A tester's error is not his, and tester activity doesn't mean he ran the build.
- **Public GitHub gets counts only.** That covers issues, PRs, commits, migrations and test fixtures, and it applies to David's health figures as well as other people's data. `site/privacy.html` doesn't list GitHub as a place user data goes.
- **Deploys and migrations reach everyone at once, on every installed build. A green merge may reach testers.** Nothing filters `testflight.yml` by path, so even a docs-only merge uploads a build.
- **The recorder counts as unmeasured until #132 has results.** Testers can record runs now, and all nine checklist items are still open. A recorded run saves to their Apple Health, so a wrong distance ends up outside Tempo.
- **`p0` now reads "broken for David or testers".** "The only user" was no longer true. David can veto this wording.
- **Interim rule, pending his call below:** agents don't read testers' free text without his go-ahead for that task.

### Shipped
- Docs only: `CLAUDE.md`, `.claude/agents/` (`em`, `scout`, `builder`) and this entry. Nothing was deployed or applied, and no rule about deploying or merging changed.

### Next up
Calls for David. These change a rule or need something only he can see, so nothing here decides them.
1. **Do the EM's standing go-aheads still apply?** It may merge on green (2026-08-27) and apply migrations and deploy functions (2026-10-09). Both were given when he was the only user, neither is in `CLAUDE.md`, and `CLAUDE.md` still says "never" for applying and deploying. His private asks page also has an open question from 2026-10-29 about pre-approving deploys, so the deploy go-ahead is less settled than it looks. Recommendation: keep both and write them into `CLAUDE.md`, with a dry run, the migration before the merge, a report of what reached testers, and his approval for any change to existing rows that aren't his.
2. **Do builds reach external testers automatically?** Agents can't see this App Store Connect setting. Recommendation: promote builds to the external group by hand, so merging on green stays safe and docs-only uploads don't reach testers.
3. **May agents read testers' free text to debug?** The privacy page says David can access the database to fix problems. It doesn't mention agents. Recommendation: keep the interim rule, and update the page if that ever changes.
4. **What does the #268 cleanup cover?** It would rewrite stored text, and its dry run shows every affected row. Recommendation: David's rows only, with other users' rows reported as a count.
5. **Does the recorder stay open to testers before #132 is done?** Nothing gates it, and the listing draft in the open PR #261 advertises it. Two recorder problems from his 2026-10-29 run are also still waiting on his OK to be filed. Recommendation: David runs the checklist now, and "What to Test" says the recorder is unmeasured until then.
6. **Where do David's account ids live?** No file an agent can read records them, and triage can't split without them. They shouldn't go in this repo. Recommendation: he confirms which accounts are his, including old anonymous ones and test accounts, and they go in private agent config.

Not in this change, because the task was `CLAUDE.md` and the agents: `docs/AUTONOMY.md`, `docs/TESTFLIGHT.md`, `docs/prd-03-tempo-mcp.md`, `/triage` and `/brief`, and comments in `Telemetry.swift`, `Supa.swift` and `testflight.yml` still describe one user. Hard limit 1 also needs a look: it says there's no path to observing the UI, but simulator builds against staging and `ScreenshotTour` now give agents one. It stays as written because that isn't a beta-of-one question, and a simulator still doesn't prove device behaviour.

## 2026-11-04: Permission before anything goes to Claude

### Decisions
- **Nothing reaches Anthropic without an explicit yes** (App Review 5.1.2(i)). Every `coach` and `plan` call goes through `CoachGateway`, which checks `CoachConsent.maySend`. Not knowing is a no. A lint test fails if anything else touches the functions client.
- **Consent comes before the intake, not just before the interview.** Every answer on the intake form exists to be handed to the coach, so someone who says no skips it and lands in the app.
- **Existing athletes are asked at launch, once**, over the app rather than on first visit to the Coach tab. A takeaway generates in the background with no coach screen open, so waiting would just leave the coach silently off.
- **A decline stays quiet.** It isn't asked again. Coach surfaces say the coach is off and offer the way back, and the You tab has a row to change it either way, including withdrawing.
- **The screen lists more than the brief did**, because the payloads do: heart rate, splits, cadence, elevation, fitness numbers, best times, check-ins and what the athlete told the coach. PRD-02 rule 5 holds the copy to the flow, not to the shorter summary.
- **The decision is stored on the phone and on `profiles`**, newest wins, and a tie between different answers resolves to the decline. No server-side check in the functions yet: the app is the only thing that calls them.

### Shipped
- `Engine/CoachConsent` (the rule), `Services/CoachGateway` (the one way out), `Services/CoachConsentStore`, `Screens/CoachConsentView`, migration `0025_coach_consent.sql`.

### Next up
- David: tap Agree once the build lands, then the device check in the PR. Migration 0025 is applied to staging and production, and he delegated the copy review.
- Fill the `[UPDATE WHEN THE CONSENT SCREEN SHIPS]` placeholder in `docs/app-store-listing.md` once that file lands on `main`.
- `site/privacy.html` (#250) summarises the same flow more briefly than this screen; bring it up to the same list.

## 2026-11-04: A plain voice for the app and the coach

### Decisions
- **No em dashes anywhere David reads, and no stock AI phrasing.** Work is split across #264 (coach), #265 (plan function), #266 (app copy), #267 (comments, docs, CI guard) and #268 (stored text).
- **The prompt is the root cause.** The model copied how its prompt was written, including "niggles", "honest" and "X, not Y" lines. So the prompt changes first and tests hold it to the same rules.
- **Dashes are enforced in code; banned words stay a prompt rule.** A dash can be mechanically replaced. Swapping a word inside a finished sentence produces garbage.
- **Left as written:** text the athlete typed, applied migrations and dated `progress.md` entries.

### Shipped
- #264: coach prompt rewrite, the dash scrubber on all coach output, and prompt tests.

### Next up
- #265 and #266, then #267. #268 runs last and needs David's sign-off on a dry run.

## 2026-11-04 (later): A size cap on each coach and plan call

### Decisions
- **Size the cap from what the app can build, not from today's traffic.** One athlete's logs would set it too low for the next one. The `coach` cap sits above a full 200-message recap with the context at the app's own ceilings, and a test pins that.
- **Measure the prompt as well as the body.** The coach pretty-prints `context`, `run` and `block`, and the indentation grows with depth, so a 10 KB body of nested arrays renders to 25 MB. A body check alone would have been easy to walk around.
- **A size refusal isn't a usage limit.** It spends nothing and counts against nothing, and it comes back as its own 413 with its own telemetry event, because a real athlete reaching it means the cap is wrong.
- **A too-large thread doesn't stop the recap backlog,** the way a used-up allowance does. Recaps run oldest first, so stopping would hold back every newer one forever.

### Shipped
- `MAX_REQUEST_BYTES` and the checks in `coach` and `plan`, tests through the real handlers, and the refusal state in the app. Written, not deployed.

### Next up
- David deploys both functions (steps in the PR).

## 2026-11-04 (later): One proposal at a time, and the athlete's word reaches the card

Found in two fresh-account setups from that day: one run correction proposed four times, three memory cards in one reply, and "5 days, Friday long runs" lost when Confirm wrote the form's 6 days and Sunday.

### Decisions
- **At most one card can be answered in a conversation, and it must reflect the latest thing the athlete said.** A newer card replaces an older one. When the athlete says something and the coach answers without proposing the card again, it closes. A card also closes after 24 hours.
- **A card the coach forgets to repeat closes rather than stays up.** Forgetting costs one message. The other way round, a stale Confirm writes the wrong plan. Reversible: `OpenProposal.status` is one function.
- **Closing is worked out from the transcript, not stored.** No migration, and old conversations are covered as soon as this ships.
- **An acknowledgement gets no card tools.** A tap reached the model as "Confirmed — X", which it read as agreement to X. It can describe a next step in words and ask.
- **The form is where the conversation starts, not where it ends.** Answers changed in chat travel in `create_plan.intake_changes`, and only those outrank the form. The model's echo of the form still doesn't, which is the #184 lesson.
- **During setup, memories save without a card,** like every other interview answer. Outside setup they are the lowest-ranked card.
- **A time said in plain speech counts as stated** ("under 20 minutes", "sub-3"). This reverses a #239 choice: reading only colons turned back the time the athlete had just asked for.

### Shipped
- `Engine/OpenProposal.swift`, `IntakeStamp.revised`, a target and week line on the plan card, and `coach/proposals.ts` with its prompt rules. The coach function is written, not deployed.

### Next up
- Held until after Friday's run, like #269: this PR stays unmerged because other sessions deploy `coach` from `main`. Then merge #269, rebase this onto it (its prompt moves to `prompts.ts`), deploy `coach`, and merge straight after.
- Device check: run a fresh intake, change an answer in chat, and confirm the card shows the change.

## 2026-11-04: Per-user usage limits before the public listing

### Decisions
- **Each kind of call has its own hourly and daily allowance:** chat, takeaway, block review, thread recap and plan. Background work can't use up an athlete's chat.
- **The limits live in a table, not in code.** Tuning one is an `update`, with no redeploy of the live coach.
- **A limiter that can't answer lets the call through.** It guards the bill, not access, so a missing migration or a database fault must not take the coach away. A caller PostgREST refuses (401/403) is the exception, because the caller controls that header.
- **Being limited is its own state in the app,** drawn in a neutral color and saying when it resets. It never reads as a connection failure or lost data.
- **Per-user limits don't bound the bill alone,** because anonymous accounts can still be minted per IP. The hard bound is a spend limit on the Anthropic side.

### Shipped
- Migration 0024 (`usage_limits`, `usage_counters`, `claim_usage`), the gate in `coach` and `plan`, and the limited state in every caller. Live on production: `coach` v24 and `plan` v10, which also took #245 and #246 live.

### Next up
- David sets the Anthropic spend limit and the anonymous sign-in limit, and sends one coach message on his phone as the device check.
- Cap the size of a request: limits count calls, and the client still decides how large each one is.

## 2026-11-03: App Store listing drafted

### Decisions
- **Marketing assets never show real data.** Screenshots and the preview come from a fictional runner on a local stack, because the repo is public. See `appstore/README.md`.
- **The listing only claims what ships today.** "On track" means projected finish against goal, not the Drift Detector, whose hero chart hasn't shipped. It makes no privacy slogans or medical claims, and names no competitors.

### Shipped
- [[app-store-listing]]: metadata, age rating, App Privacy answers and review notes.
- Header, search and universal art, 8 screenshots at 6.9" and 6.1", and a 24-second preview.

### Next up
- Blockers in [[app-store-listing]]: in-app consent before data goes to Anthropic (guideline 5.1.2(i)), the privacy URL (#250), coach rate limiting.
- David's calls: the app name, given "Tempo: Home Workout & Fitness" is already in the category, and whether a public listing should wait for the Drift Detector (PRD-02 rule 8).

## 2026-10-15 (later): Drift Detector PRD, revised after the repo audit

### Decisions
- **Positioning:** Tempo is the private, cross-platform layer that answers "Am I on track?" on top of whatever a runner already uses. Core v1 feature: the Drift Detector. See [[prd-02-drift-detector]].
- **Drift is measured against Tempo's own expected curve** toward the goal time, not against the goal itself. Tiers: on track < 2%, drifting 2–< 5%, off track ≥ 5%. Thresholds are tunable config.
- **Money: free for now; pricing later.** The planning session leaned toward paid coaching. That's deferred, and the free decision above stands.
- **The privacy claim is removed for now.** "We never store or sell your data" isn't true of the current backend. No privacy copy ships until it maps to a real data flow.
- **The plan engine stays.** The Drift Detector judges progress; a drift alert never rewrites a plan by itself.
- **Rule 3 holds: numbers from code, words from the model.** Existing violations are tracked: run corrections (#206), goal time and plan volume (#207, needs David).
- **Apple Health only.** No Strava API. #106 (auto-upload to Strava) closed as not planned.
- **The work queue is GitHub Issues**, not Linear.

### Shipped
- PRD-02 filed with the repo audit (§14). README corrected: Health-only data and no paywall.
- Issues filed and building: #204 (coach prompt hard-coded to David), #205 (made-up projection when no run qualifies), #206 (run corrections computed in code).

### Next up
- Go/no-go on the Drift Detector issue list (PRD §9, adjusted by the audit) and on the §11 `CLAUDE.md` rules.
- #207: decide on goal time and plan volume under rule 3.
- Figma design-system link before the hero chart (the Figma connector needs authorizing).

## 2026-10-15: Tempo stays free; intake v2 drafted from Runna

### Decisions
- **Tempo is free, with full access.** No feature, plan, or piece of your own data sits behind a paywall. If money ever comes into it, through optional ads or a donation, it buys a nicer experience, never more access. No payment or donation UI gets built now.
  - *Why:* Runna charges about $120 a year on top of a Strava subscription, so some runners pay $180–200 a year between the two, and there's no free path past the trial. When a very good plan costs almost nothing to generate, holding it hostage behind a subscription is exactly the problem Tempo exists to fix.
- **Onboarding stays distance-first.** No race database or race search. The race name stays optional free text.
- **Intake v2 direction**, from David going through Runna's onboarding: ask *why* you're training, your experience level, a self-reported current race time, which days you're free, and an honest "who this is built for" line. See [[prd-01-intake-v2]] (draft).

### Shipped (overnight 14–15 Oct)
- Recover a killed run at launch (#170), the live run screen (#171), the post-run save screen (#173)
- Race mode files the run as the goal's race (#174), Lock Screen Live Activity + Dynamic Island (#176)
- Run Detail journal (#177), treadmill rescale to the console distance (#180, #182)
- TestFlight revokes the development certificate each run mints (#103)

### Found
- The goal for a 5K was saved as a marathon: a create_plan card with no distance falls back to marathon (#184).
- The projection is always a marathon projection, whatever the goal (#185).

### Next up
- #184, #185 (p0, building), #186 keyboard/tab bar (p2, building)
- #183: reuse one CI development certificate, which ends the revocation emails
- #96 needs David's call: Coach v2 (chat threads, #87) or the data layer first
- PRD-01 open questions
