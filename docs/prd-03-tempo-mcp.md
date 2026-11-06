---
tags: [tempo, prd, mcp]
status: draft
created: 2026-11-03
---

# PRD-03: A Tempo MCP server

Project: [[README|Tempo docs]] · Decisions: [[decision-log]] · Related: [[prd-02-drift-detector]]

> Status: **draft**. Written 2026-11-03 from a conversation with David ("an MCP for your Tempo account?"). Nothing here is built. The auth phasing (§6) and the open questions (§10) are David's calls. No issues get filed until he has read this.

## 1. What this is

A read-only MCP server over your own Tempo data. Any MCP client (Claude Code, and later claude.ai, Claude Desktop and the Claude phone app) can ask Tempo things like "how's this week looking?", "am I on track for the goal?" or "show me my last five long runs". It answers with the numbers Tempo already computes, not a raw table dump.

## 2. Why

**For you, now.** You could ask about your training from any Claude surface, in a conversation that can also see your calendar, your notes or a race's course page, without opening the app. The answers come from the real archive (2,000+ runs), the active plan and your check-ins.

**For the agents.** Scout, triage and EM read the database today through the Supabase MCP with raw SQL. Each of them relearns the same scars: corrected runs win over HealthKit totals, superseded duplicates are filtered out, the archive is capped at 1,000 rows unless you page it. A Tempo MCP holds those rules once.

**Strategically.** PRD-02 §2 names the danger: an app that is "a prompt + a UI on a model" gets absorbed by AI harnesses. What survives is what a generic connector can't copy, which is long-term training history and Tempo's own model of where you should be. An MCP doesn't give that away. It makes Tempo the place those harnesses have to come to for it.

### The tension with PRD-02

PRD-02 also says Tempo targets "the 99% who don't use Claude Code" and won't set up MCP servers. That still holds. **This is a power-user surface, not the product.** It stays read-only, it stays small, and it never jumps the Drift Detector in the queue.

## 3. Principles

1. **Read-only.** The coach never writes data itself. It returns `proposed_actions`, and the app shows a confirm card that you tap. An MCP client has no confirm card, so v1 has no write tools. A future "propose" tool could queue a proposal that shows up as a confirm card in the app, but that's out of scope here (§8).
2. **Numbers come from code (PRD-02 rule 3).** The MCP returns finished numbers: weekly totals, fitness, form, projection. It never hands the client model 2,000 rows and expects it to add them up. A model summing mileage is the model computing a metric, and that's exactly what rule 3 forbids. Every aggregate a runner asks for regularly gets its own tool.
3. **One engine.** Fitness/fatigue/form and readiness live in `Engine/LoadModel.swift` and stay there. The MCP reads values the app has already computed and saved (§5). It does not get a TypeScript port. `plan/generator.ts` already keeps a port of `TrainingPaces` in sync by hand, and one is enough.
4. **The database's truth.** Corrections win (`runs.corrected`), superseded duplicates are excluded (`superseded_by is null`), distances come out in your units (`profiles.units`), and every list is paged.
5. **Runs as you.** Queries run under your own identity so Row Level Security does the scoping, wherever the auth phase allows it (§6). The service-role key never leaves Supabase secrets.

## 4. Tools (v1)

| Tool | Returns | Comes from |
|---|---|---|
| `get_status` | Fitness, fatigue, form and readiness with its label, the goal, the projected finish against the goal, and `as_of` | `metrics_daily` (§5), `goals`, `plans.projected_finish_s` |
| `get_week` | This week's planned sessions and their status, miles done against miles planned, and today's check-in | `plans`, `plan_weeks`, `sessions`, `check_ins` |
| `get_weekly_mileage` | Weekly totals for the last N weeks (default 12) | `runs`, aggregated on the server |
| `list_runs` | A page of runs: date, distance, time, pace, average HR, whether it was edited, and the journal headline. Filters: date range, minimum distance, `long_only` | `runs` |
| `get_run` | One run in full: splits, efforts, the coach's cached takeaway, journal and correction note | `runs`, `run_efforts` |
| `get_bests` | Longest run, fastest effort at each distance, biggest week | `run_efforts`, `runs` |

**`get_drift`** comes next, and it's the tool PRD-02 would most want: "am I on track?", answered from anywhere. The math is already on main as pure engine code: `Engine/FitnessEstimate.swift` (#244), `Engine/TrajectoryCurve.swift` (#235) and `Engine/Drift.swift` (#236). None of it is wired into a screen or saved anywhere yet. Once the wiring lands, `get_drift` reads the saved reading (§5), the same way `get_status` does: current fitness, this week's expected value, drift %, the tier, and `as_of`.

Every response carries `as_of` and `units`. Tool descriptions say plainly that the numbers are Tempo's and must be quoted, not recomputed.

## 5. The hard part: the numbers live on the phone

`LoadModel.compute(runs:checkInOK:)` runs in the app on every refresh. Nothing on the server has its output.

**The fix is already half there.** `0001_init.sql` created `metrics_daily` (`ctl`, `atl`, `form`, `readiness`, with RLS on `user_id`), and nothing has ever written to it. The app starts upserting today's row after each `LoadModel.compute`:

- A pure function in `Engine/` maps `FitnessMetrics` to a row. This is where the tests go.
- `Services/` does the upsert. If it fails, it fails quietly and the next refresh retries. The screen never depends on it.
- Readiness already honors the check-in cap ("the athlete's word outranks the math"), so the saved row does too.
- When the Drift Detector gets wired in, the same row carries its reading. `metrics_daily` has no columns for it, so that wiring PR adds them (fitness estimate, expected value, drift %, tier). One row a day, one place the server looks.

**The cost is freshness.** The numbers are as fresh as the last time you opened the app. `get_status` returns `as_of`, and the tool description tells the client to say "as of Tuesday morning" when the reading is stale. Recomputing on the server would fix this, but at the price of a second engine. Not worth it for a beta-of-one.

## 6. Auth (David's decision)

This is the real design question. You sign in anonymously: there's no email and no password, just a session in the iPhone's storage. So there's nothing to type into a sign-in page.

What the clients accept, as of 2026-11-03:
- **Claude Code** connects to remote MCP servers with a custom header, e.g. `Authorization: Bearer <token>`.
- **claude.ai, Claude Desktop and the phone app** connect from Anthropic's cloud. Connectors there expect OAuth. Anthropic's docs describe custom credentials as an option that needs their review team.
- **Supabase Auth can act as an OAuth 2.1 server** for MCP (public beta since 2025-11-26). It issues real user tokens, so RLS keeps working. You still build the MCP server, and the consent page too.

### Phase 1: personal access token (Claude Code)

- The You tab gets "Connect Claude": generate a token, show it once, revoke it later.
- A new table `mcp_tokens` holds `user_id`, the token's hash (never the token), `created_at`, `last_used_at` and `revoked_at`.
- You paste the token into your user-level Claude Code config (`~/.claude.json`). It never goes in the repo or in `.env`.
- **Trade-off:** a token isn't a Supabase JWT, so the function can't query as you under RLS. It looks up the `user_id` from the hash and then queries with the service role. Every query goes through one helper that always applies `user_id`, and a test pins that. This is weaker than RLS, and it's the main reason Phase 2 exists.

### Phase 2: OAuth (the phone)

- Link an email to your anonymous account. Supabase keeps the same user id when an anonymous user adds an identity, so all your runs stay attached. This touches your live account, so you do it, on the device.
  - It also closes an old scar. `supabase/ops/carry_over_athlete.sql` exists because your whole history is owned by an anonymous session in one iPhone Keychain: a build signed by another team would open empty. With an email linked, your history belongs to an identity you can sign back into.
- Turn on Supabase's OAuth 2.1 server, with dynamic client registration.
- Build the consent page. One risk to check first: Supabase edge functions on the default `*.supabase.co` domain may not serve HTML as a page, so the consent page may need a static host.
- The MCP function now gets your real JWT, queries under RLS, and the Phase 1 service-role path is deleted.

**Recommendation:** Phase 1 first. It's small, it doesn't touch your account's identity, and it lets us iterate on the tools, which are the part that matters. Phase 2 follows once the tools have earned a place on your phone.

## 7. Shape

- A new edge function `supabase/functions/mcp/` in Deno, beside `coach` and `plan`. It uses the MCP TypeScript SDK over Streamable HTTP; check the exact package and version when building.
- Tool handlers are thin: query, then a **pure shaping function** (rows in, response out) that gets `deno test` coverage, in the same pattern as `coach/history.ts`.
- No Claude call inside the function. The client brings its own model, and the function only returns data.
- `deno check` joins CI with the other functions.

## 8. Out of scope

- Write tools of any kind, including amend run, log run and move session.
- Anyone else's data. Beta-of-one, one account.
- Strava's API (PRD-02 §2 still holds).
- Server-side recompute of the engine (§5).
- Packaging this for other runners. If Tempo ever has users other than you, revisit §2's tension first. That may come soon: #253 asks what the bar is for external TestFlight. Phase 1 tokens are per user and already scoped by `user_id`, so a second tester doesn't break anything, but nobody else should be handed this before Phase 2.

## 9. Proposed issues (not filed)

| # | Issue | Label | Note |
|---|---|---|---|
| A | feat: the app saves daily load metrics to `metrics_daily` | `agent-ready` p1 | Pure mapping in `Engine/` with tests; a device check confirms rows appear |
| B | feat: `mcp_tokens` migration plus "Connect Claude" in the You tab | `needs-device` p1 | Phase 1 only. The migration goes in the PR and David applies it |
| C | feat: `mcp` edge function with the v1 tools in §4 | `agent-ready` p1 | Depends on A and B. Shaping functions tested; David deploys it |
| D | spike: Phase 2 OAuth (link an identity, Supabase OAuth server, consent page hosting) | `needs-david` p2 | Starts the day after C proves itself |
| E | feat: `get_drift` | `needs-david` p2 | Blocked on wiring the Drift Detector into the app and saving its reading to `metrics_daily`. No issue for that wiring is filed yet |

## 10. Open questions for David

1. Phase 1 first, or go straight to OAuth so it works on your phone from day one?
2. Is a reading that's "as fresh as your last app open" acceptable, or does `get_status` need to be live?
3. Should journal text and coach takeaways go through the MCP? It's your words leaving Tempo for whatever client you connect. PRD-02 §4 already says no privacy claim ships until data flows are mapped, and this adds one to the map.
4. Should the agents (scout, triage, EM) switch from raw SQL to the MCP once it exists, or keep both?

## 11. How it gets verified

- **CI:** engine tests for the `metrics_daily` mapping, `deno test` for every shaping function plus the user-scoping test, and `deno check`.
- **Your check (needs device):** open Tempo and pull to refresh. Then, in Claude Code with the token configured, ask "what's my form today, and how many miles have I run this week?" The numbers should match the readiness card and Today's mileage to the tenth. If they're off at all, it's a bug, not rounding.

Sources for §6: [Claude custom connectors (help center)](https://support.claude.com/en/articles/11175166), [Connector authentication (Claude docs)](https://claude.com/docs/connectors/building/authentication.md), [Supabase MCP authentication](https://supabase.com/docs/guides/auth/oauth-server/mcp-authentication), [Supabase OAuth 2.1 server changelog](https://supabase.com/changelog/38022-oauth-2-1-server-capabilities-for-supabase-auth).
