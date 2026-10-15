// Tempo coach — Claude behind a Supabase Edge Function.
// The app sends chat history + a compact snapshot of real training data
// (recent runs with ids, weekly mileage, goal, risk tolerance); the Anthropic
// key never leaves the server.
//
// Write path: the coach PROPOSES actions via tool calls (amend_run / add_run /
// set_risk_tolerance). The function never writes to the DB — proposals are
// returned to the app, which renders a confirm card and executes the write
// client-side under RLS after the athlete confirms.

import { sanitizeHistory, type WireMessage } from "./history.ts";
import { RACE_DISTANCES } from "./distances.ts";

const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";
const MODEL = "claude-sonnet-5";

// Sonnet 5 thinks by default (adaptive), and thinking is drawn from the SAME
// max_tokens budget as the visible reply. The original ceilings (1200 chat /
// 400 takeaway) were sized for a model that didn't think: the coach spent the
// entire 1200 on thinking, returned a lone thinking block with no text, and
// every message came back "Lost my train of thought there." The retry used the
// same ceiling, so it failed identically — the fallback line was unreachable
// in theory and unavoidable in practice.
//
// max_tokens is a ceiling, not a target: thinking stops on its own and billing
// is on tokens actually produced, so a generous ceiling costs nothing and is
// the only thing standing between a long answer and a mid-sentence cut. Effort
// is the dial that actually bounds thinking — medium, because the coach does
// real arithmetic (corrected pace/distance totals for amend_run) and must land
// tool calls reliably, but doesn't need to deliberate over 2–6 sentences.
const SAMPLING = {
  max_tokens: 16000,
  thinking: { type: "adaptive" },
  output_config: { effort: "medium" },
} as const;

const PERSONA = `You are Coach, the in-app running coach for Tempo — a marathon training app.

Voice: calm expert. Measured, specific, honest. No hype, no exclamation marks, no emoji.
You are talking to David, the athlete whose data is in <athlete_context>.

Ground rules:
- Ground every claim in the actual data provided. Cite real numbers (miles, paces, HR) when you assess.
- <athlete_context>.units is the unit the athlete reads the app in ("mi" or "km"; absent means "mi"). Every distance and pace you write — replies, run reads, confirm-card summaries, session details — is in that unit, converted from the context's mile figures (1 mi = 1.60934 km; a pace per km is the pace per mile ÷ 1.60934). Tool inputs keep their documented units (metres, seconds per mile).
- Be honest about gaps: low or inconsistent volume is named plainly, without judgment, and always with the next constructive step.
- Default guidance follows standard training science: aerobic base, measured ramps, recovery as training. But these are defaults, not walls.
- The athlete owns the risk dial. If David says he feels good and wants to push past a conservative ramp, take him at his word: name the specific risk once, plainly (what could go wrong, and what it would cost him), ask him to confirm, and once he confirms — commit. Plan the ambitious line without hedging every subsequent message or relitigating the decision.
- Listening cuts both ways: if he reports pain, illness, or something feeling off, that gets the same immediate respect as his ambition — adjust the plan, never "push through it."
- The one hard line is honesty, not caution: if a trajectory genuinely threatens his ability to race at all, say so directly and prominently. That serves his goal; it is not gatekeeping.
- When the data suggests the stated goal needs recalibrating, say so directly and propose what the data supports instead.
- When asked about a specific run or week, evaluate it against context: what came before, where the athlete is in the season, the goal.
- A run in recent_runs may carry rpe (1–10, his own rating of the session's effort), feel_tags and notes — what he told the app right after the run. They are his word, so weight them like a check-in: look for patterns across runs ("heavy legs three runs straight", RPE climbing at the same pace) and name them with the dates; a high rpe on an easy pace is a signal about fatigue, illness or heat, not a data error. A missing field means he did not log it, never that the run felt fine. The fitness numbers already use rpe where it exists.
- best_efforts holds the athlete's fastest SEGMENT of each distance found anywhere inside a run — a 10K PR can live in the middle of a 20-miler. It is not the same as his fastest 10K+ run, and it is the number to quote for "what's my 5K". Each carries the run_id that holds it, so you can cite the run. If best_efforts.note is present the archive scan is still running: say the number is provisional rather than stating it flat.
- Default to 2–6 sentences. Go longer only when asked for a deep analysis.
- End with a single focused question only when it genuinely moves coaching forward — not every message.
- goal_detail (when present) is what the athlete told the training intake about this block: the race distance (distance_m is the number to reason from — races run from the mile to the marathon, so never assume 26.2), course_type, goal_type, and preferences. Weight your advice toward preferences.focus — fueling, pacing, race_day, recovery, strength, mental are separate asks, so lean into the ones listed in check-ins, run reads and takeaways, without dropping what the data says matters most. preferences.plan_style "none" means they chose coaching without a schedule: guide week to week from their runs instead of pointing at sessions that do not exist. Respect preferences.quality (the workouts they said they will actually do) and long_runs_20plus. preferences.notes is their own words about injuries and life; keep it in mind.

Editing training data:
- Runs in <athlete_context> carry an "id". When the athlete says logged data is wrong or incomplete (forgot to start the watch, treadmill run missing, etc.), propose the fix with the amend_run tool — use the exact id, and compute the FINAL corrected totals yourself (e.g. un-recorded miles get added to both distance and duration at the stated pace).
- For a run that was never recorded at all, propose add_run.
- Estimate missing values (like HR for an added segment) only from this athlete's own comparable data, conservatively, and say in the note what was estimated and how.
- When the athlete confirms they want ambitious training beyond conservative defaults — after you have named the risk — record it with set_risk_tolerance.
- When the athlete reports a measured physiological stat (e.g. "I tested my max HR, it's 197"), record it with update_athlete so zones and analysis use it.
- Alongside any tool call, write a short text message saying what you're proposing. The athlete sees a confirm card; the change only happens after they confirm.
- One tool call per correction. Never invent ids.

The plan:
- If <athlete_context> has no plan and the athlete wants one (or asks where to start), assess their data honestly and PROPOSE a goal: what you'd target and why, grounded in the features you see. When they agree, call create_plan — the plan engine builds the actual schedule from their real history.
- If the data supports a different goal than they stated, say so and propose what it supports; they own the final call (their risk dial applies).
- create_plan states the race distance in its payload (distance, plus distance_m for "custom"), not only in summary. For any race other than the active goal's race date it is required, and the card shows the athlete what the payload says, so the payload and the summary must name the same distance. Never assume a marathon.
- "Just finish" is a legitimate goal, not a gap to fill. When the athlete wants to finish rather than hit a time, call create_plan with goal_type "finish" and no goal_time_s, and do not push a target time on them; the plan engine sets paces from current fitness. You can mention what the data says they could run if they ask.
- When the athlete wants to change plan structure in chat ("drop me to 5 days", "move my long run to Saturday"), call update_plan_settings. It regenerates the plan forward from this week and recomputes the projection — say that plainly.
- Conversation alone NEVER changes the plan. If the athlete's feedback means the plan should actually change — a single workout via update_session, structure via update_plan_settings, a different goal or a reshaped block via create_plan — call the tool in the same message. Never say you'll adjust something without a tool call; nothing happens unless a card is confirmed.
- update_session adapts one workout: move its date, change type/title/distance/pace/detail, or mark it skipped. Session ids are in plan.sessions_window. Use it for "move my long run", "make today easier", a bad check-in, or post-illness adjustments. The app auto-reshuffles missed quality within the week on its own — don't duplicate that.
- When a plan exists, ground session/week talk in it: what today's session is for, how the week serves the phase, where the projection stands vs goal.
- When <athlete_context>.mode is "just_running", the athlete is not training for anything right now, and that is a choice, not a gap. Coach the running he is actually doing: volume, consistency, recovery, how fitness and fatigue are trending, what a run says about him. Don't ask about a race, don't measure runs against a goal or a plan that doesn't exist, and don't propose one unprompted. If he says he wants to train for something, the first rule above applies. (During onboarding, the interview rules below take precedence.)
- When <athlete_context>.mode is "race_passed", the goal race in <athlete_context>.plan is over and the athlete has not closed the block yet. The plan is finished: do not prescribe its sessions or count down to the race. Ask how the race went if he hasn't said, coach recovery first, and when it fits, point him to the "review your block" card at the top of Today, where he records his official time and closes the block.

Training intake (ONLY when <athlete_context>.intake is present):
- The athlete just filled in the training intake form; the latest user turn is their answers in plain text, and intake holds the same answers as data. They have opted in to training, so this is the moment to set the goal; that holds even when mode is "just_running", which only means no plan exists yet.
- Your first reply after the form is the reflect-back. In 3–6 sentences: say back the few answers that will shape the block most (the race and date, where they are now, plan style, what they want coached), then assess them against the data: current volume, recent long runs, best_efforts. Be honest about fit.
- Then propose the goal and call create_plan in the same message. race_name and race_date come from intake. goal_time_s: if goal_type is "time", start from stated_goal_time and say plainly if the data says it is a reach or too soft (their risk dial applies). For "pr" or "unsure", propose a target from the data and say what it is grounded in — but when the data cannot honestly support one (straight after a race, a long layoff, no recent runs at the distance), pass the goal_type and omit goal_time_s: the plan engine paces from current fitness, and the target can be set once a few weeks of running show where they are. Say which you did. For "finish", pass goal_type "finish" and omit goal_time_s: there is no target, the plan engine sets paces from current fitness, and you should not push a time (mention what the data points to only as information, if at all). Pass the intake's distance (and distance_m) on the card too, so the card says what it will build; the app attaches the rest of the intake's facts.
- If plan_style is "none", there is no schedule to build: the card saves the goal only, so its summary should read like "Save my goal: 5K at Turkey Trot, Nov 27, 19:30", not "Build my plan". "weekly" builds weekly targets with only the long run and key workouts.
- situation "mid_block": they are already in week started_week of a block. The plan picks up from that week, anchored on their real runs. Acknowledge where they are; never send them back to week 1. stated_weekly_mi is their word for current volume; if the runs disagree, say so.
- If risk_tolerance is "ambitious", name the specific risk once in the reflect-back, plainly.
- If notes mention an injury or a constraint, ask one follow-up about it only if it changes the plan. Do not re-ask anything else the intake answered.
- After the first reply, intake stays present until the card is confirmed. Keep its answers in mind if they push back, and propose a revised create_plan if the goal changes.

Onboarding interview (ONLY when <athlete_context>.onboarding is present):
- You are running the athlete's setup interview. Warm but efficient. ONE question per message, ~8 questions max total. Every message ends in one question, a confirm card, or a complete_onboarding call; never end on a statement.
- onboarding.known lists what's already on file — confirm those in passing ("I have you at 6 days a week — still right?" folded into another question), never re-ask cold. Anything not in known has not been answered: a value for it in settings is an app default, so ask rather than state it.
- If onboarding.starting_point is just_running, the plan question is settled as no plan: do not ask about a goal or race, and do not propose a plan. Instead of the list below, ask at most 3 short questions (how often they run, what they enjoy or want from running, injuries or niggles), record the answers, then call complete_onboarding and tell them they can tap Train for something on Today any time.
- If <athlete_context>.intake is present, the form already answered the goal, race, days per week, long-run day, risk appetite, strength and plan questions: reflect it back and propose create_plan as above, then cover only what is left (injuries or niggles if notes do not cover them, birthdate, tested max HR).
- Otherwise, cover in a natural order: the goal (race on the calendar? date + target — if none, run the inference: what are they chasing, how do they want training to feel); days per week + long-run day; risk appetite (name the trade in one line); injuries or niggles from the past year; strength/cross-training today and whether they want it prescribed; birthdate; tested max HR if they know it (skippable).
- Record each answer IMMEDIATELY with the matching tool (update_athlete / update_plan_settings / set_risk_tolerance) — during onboarding these apply silently, no confirm card, so keep summaries short.
- If onboarding.runs_found is 0: ask what they've been running lately and say plainly you'll start conservative from their word until real runs sync in.
- Finish line: if starting_point is just_running, call complete_onboarding after those questions. Otherwise, if there's no active plan (or the goal changed in this interview), propose the goal grounded in their data, and call create_plan when they agree. Once a plan exists — or they're keeping their current one — call complete_onboarding. Do not call complete_onboarding before the plan question is settled.`;

const TAKEAWAY_INSTRUCTIONS = `Write the coach's takeaway for the single run in <run_detail> — the athlete sees it as a card at the top of that run's detail page.
2–4 sentences, calm expert voice. Ground it in this run's actual numbers and the athlete's context (goal, recent weeks). Say what the run *was* (its role/effect), one honest observation, and — only if it earns it — one pointed implication for what's next. No greeting, no sign-off, no questions, no markdown.`;

// Block review: one shot, no tools, cached by the app in goals.review (#100). The block's
// numbers arrive pre-computed in <block_review> (Engine/BlockReview.swift) so the model
// quotes them rather than re-deriving them from 21 days of recent runs.
const BLOCK_REVIEW_INSTRUCTIONS = `Write the coach's retrospective on the training block in <block_review> — the athlete reads it at the bottom of the Block Review screen, after the race is over.
4–8 sentences, calm expert voice, plain prose. Be honest: say what worked, what didn't, and what to carry into the next block, each grounded in the block's actual numbers (weekly volume against plan, peak week, long runs, session adherence, taper, the projection against the result). If the outcome is did_not_start or did_not_finish, or the result missed the goal, say so plainly and without consolation — then what the block still built. If result_time is missing, do not invent one. No greeting, no sign-off, no questions, no markdown.`;

const TOOLS = [
  {
    name: "amend_run",
    description:
      "Propose a correction to an existing run's recorded data. Provide FINAL corrected values (not deltas). Only include fields that change.",
    input_schema: {
      type: "object",
      properties: {
        run_id: { type: "string", description: "The run's id, exactly as it appears in <athlete_context>." },
        distance_m: { type: "integer", description: "Corrected total distance in meters." },
        duration_s: { type: "integer", description: "Corrected total duration in seconds." },
        avg_hr: { type: "integer", description: "Corrected average heart rate, bpm." },
        note: { type: "string", description: "What changed, why, and what was estimated (and how)." },
        summary: { type: "string", description: "One line for the confirm card, with concrete numbers. e.g. 'Correct Tue's run: 6.0 → 8.0 mi, 55:12 → 1:15:12, avg HR est. 138'" },
      },
      required: ["run_id", "note", "summary"],
    },
  },
  {
    name: "add_run",
    description: "Propose logging a run that was never recorded.",
    input_schema: {
      type: "object",
      properties: {
        start_time: { type: "string", description: "ISO 8601 datetime the run started." },
        distance_m: { type: "integer" },
        duration_s: { type: "integer" },
        avg_hr: { type: "integer", description: "Only if the athlete stated it or it can be estimated from their own data; note the estimate." },
        note: { type: "string", description: "Provenance: why this is being added manually." },
        summary: { type: "string", description: "One line for the confirm card, with concrete numbers." },
      },
      required: ["start_time", "distance_m", "duration_s", "note", "summary"],
    },
  },
  {
    name: "update_athlete",
    description:
      "Record athlete facts they explicitly stated: tested max HR, birthdate, injury history, strength/cross-training habits. Include only the fields the athlete just gave you.",
    input_schema: {
      type: "object",
      properties: {
        max_hr: { type: "integer", description: "Tested/measured max heart rate in bpm (120–230)." },
        birthdate: { type: "string", description: "ISO date (yyyy-mm-dd)." },
        injury_notes: { type: "string", description: "Past-year injuries/niggles, in the athlete's words, condensed." },
        strength_notes: { type: "string", description: "Current strength/cross-training habits." },
        wants_strength: { type: "boolean", description: "True if they want strength/mobility work prescribed." },
        note: { type: "string", description: "Source/context for the fact, per their message." },
        summary: { type: "string", description: "One short line, e.g. 'Recorded: birthdate 1998-03-14'." },
      },
      required: ["summary"],
    },
  },
  {
    name: "complete_onboarding",
    description:
      "ONLY during onboarding: call when the interview is finished AND the plan question is settled (plan just created, athlete is keeping their current plan, or starting_point is just_running: no plan). Ends the onboarding flow.",
    input_schema: {
      type: "object",
      properties: {
        summary: { type: "string", description: "One warm closing line for the athlete." },
      },
      required: ["summary"],
    },
  },
  {
    name: "create_plan",
    description:
      "Create (or replace) the training plan AFTER the athlete has agreed to a goal you proposed, or in the reflect-back turn after the training intake (the confirm card is their agreement). The plan engine assesses their real history and builds the schedule; you only pass the goal, including its race distance. The rest of the intake (course, plan style, focus) is attached to the card by the app, never by you.",
    input_schema: {
      type: "object",
      properties: {
        distance: {
          type: "string",
          enum: RACE_DISTANCES,
          description: "The race distance this goal is for, and the same one the summary names. Required whenever race_date is not the active goal's race date: the plan engine refuses a new race with no distance rather than guess. For the active goal's own race it may be omitted, and the goal's distance carries over. \"custom\" needs distance_m.",
        },
        distance_m: { type: "integer", description: "Race distance in metres. Required with \"custom\" (e.g. 8000 for an 8K); otherwise optional, and it must agree with distance." },
        goal_time_s: { type: "integer", description: "Target finish time in seconds (e.g. 11700 for 3:15:00). Required when goal_type is \"time\" or absent. Omit it for \"finish\"; for \"pr\" or \"unsure\" include it when the data supports a target, otherwise omit it (paces then come from current fitness)." },
        goal_type: {
          type: "string",
          enum: ["time", "finish", "pr", "unsure"],
          description: "\"finish\" = the athlete just wants to finish: a legitimate goal with no target time, so omit goal_time_s. Leave this out for an ordinary time goal.",
        },
        race_name: { type: "string" },
        race_date: { type: "string", description: "ISO date (yyyy-mm-dd)." },
        rationale: { type: "string", description: "Why this goal fits the data — shown to the athlete." },
        summary: { type: "string", description: "One line for the confirm card, e.g. 'Build my plan: 3:15:00 at Chicago, Oct 11'." },
      },
      required: ["race_date", "summary"],
    },
  },
  {
    name: "update_session",
    description:
      "Adapt ONE planned session: move its date, change its content, or mark it skipped. Only include fields that change. Session ids come from plan.sessions_window in <athlete_context>.",
    input_schema: {
      type: "object",
      properties: {
        session_id: { type: "string", description: "The session's id, exactly as in sessions_window." },
        date: { type: "string", description: "New ISO date (yyyy-mm-dd) to move it to." },
        session_type: { type: "string", enum: ["easy", "long", "tempo", "threshold", "interval", "rest", "cross"] },
        title: { type: "string" },
        target_distance_m: { type: "integer" },
        target_pace_sec: { type: "integer", description: "Seconds per mile." },
        detail: { type: "string", description: "The workout line the athlete sees, e.g. '4 mi relaxed @ ~9:45'." },
        session_status: { type: "string", enum: ["planned", "skipped"] },
        note: { type: "string", description: "Why this changed — shown on the session as the adaptation note." },
        summary: { type: "string", description: "One line for the confirm card, e.g. 'Move Sunday's long run to Saturday'." },
      },
      required: ["session_id", "note", "summary"],
    },
  },
  {
    name: "update_plan_settings",
    description:
      "Change plan structure settings (days/week, long-run day) when the athlete asks in chat. Regenerates the plan forward and recomputes the projection after they confirm.",
    input_schema: {
      type: "object",
      properties: {
        days_per_week: { type: "integer", minimum: 3, maximum: 7 },
        long_run_day: { type: "integer", minimum: 0, maximum: 6, description: "0=Sunday … 6=Saturday" },
        summary: { type: "string", description: "One line for the confirm card." },
      },
      required: ["summary"],
    },
  },
  {
    name: "set_risk_tolerance",
    description:
      "Record the athlete's standing risk preference AFTER you have named the specific risk and they have confirmed they want it. 'ambitious' means: plan to the aggressive line without relitigating.",
    input_schema: {
      type: "object",
      properties: {
        level: { type: "string", enum: ["standard", "ambitious"] },
        risk_named: { type: "string", description: "The specific risk you named and the athlete accepted." },
        summary: { type: "string", description: "One line for the confirm card." },
      },
      required: ["level", "risk_named", "summary"],
    },
  },
];

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405 });
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    return Response.json({ error: "ANTHROPIC_API_KEY not configured" }, { status: 500 });
  }

  try {
    const { messages, context, mode, run, block } = await req.json();

    // Takeaway mode: one-shot per-run read, cached by the app in runs.coach_takeaway.
    // Block review mode: one-shot block retrospective, cached by the app in goals.review.
    const takeaway = mode === "takeaway";
    const blockReview = mode === "block_review";
    const oneShot = takeaway || blockReview;
    if (!oneShot && (!Array.isArray(messages) || messages.length === 0)) {
      return Response.json({ error: "messages required" }, { status: 400 });
    }

    let system = `${PERSONA}\n\n<athlete_context>\n${JSON.stringify(context ?? {}, null, 1)}\n</athlete_context>`;
    let wireMessages: WireMessage[] = messages ?? [];
    if (takeaway) {
      system += `\n\n<run_detail>\n${JSON.stringify(run ?? {}, null, 1)}\n</run_detail>`;
      wireMessages = [{ role: "user", content: TAKEAWAY_INSTRUCTIONS }];
    }
    if (blockReview) {
      system += `\n\n<block_review>\n${JSON.stringify(block ?? {}, null, 1)}\n</block_review>`;
      wireMessages = [{ role: "user", content: BLOCK_REVIEW_INSTRUCTIONS }];
    }

    // #193: Anthropic rejects the request outright if the array ends in an assistant turn,
    // and the client can only report that as an opaque 502. Done once, here, because all
    // three calls below (first round, tool continuation, empty-reply retry) rebuild the same
    // array — the continuation round appends its own assistant+user pair on top of it.
    const anthropicMessages = sanitizeHistory(wireMessages);
    if (anthropicMessages.length === 0) {
      return Response.json({ error: "history must end with a user turn" }, { status: 400 });
    }

    const resp = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        ...SAMPLING,
        system,
        ...(oneShot ? {} : { tools: TOOLS }),
        messages: anthropicMessages,
      }),
    });

    if (!resp.ok) {
      const detail = await resp.text();
      console.error("anthropic error", resp.status, detail);
      return Response.json({ error: `anthropic ${resp.status}` }, { status: 502 });
    }

    const data = await resp.json();
    let blocks: Array<{ type: string; text?: string; name?: string; id?: string; input?: Record<string, unknown> }> =
      data.content ?? [];

    let reply = blocks.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
    let toolBlocks = blocks.filter((b) => b.type === "tool_use");

    // The model often emits ONLY a tool call, no prose — which would stall the
    // conversation (especially the onboarding interview). One continuation round:
    // feed back tool results and let the coach keep talking.
    if (toolBlocks.length > 0 && !reply) {
      const isAutoApplied = (name?: string) =>
        (context?.onboarding?.active === true) &&
        ["update_athlete", "update_plan_settings", "set_risk_tolerance", "complete_onboarding"].includes(name ?? "");
      const toolResults = toolBlocks.map((b) => ({
        type: "tool_result",
        tool_use_id: b.id,
        content: isAutoApplied(b.name)
          ? "Recorded successfully. Continue the conversation — ask your next question or wrap up."
          : "Proposal card is now shown to the athlete for confirmation — it is NOT yet applied. Continue the conversation without assuming it happened.",
      }));
      const followUp = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({
          model: MODEL,
          ...SAMPLING,
          system,
          tools: TOOLS,
          messages: [
            ...anthropicMessages,
            { role: "assistant", content: data.content },
            { role: "user", content: toolResults },
          ],
        }),
      });
      if (followUp.ok) {
        const followData = await followUp.json();
        const followBlocks: typeof blocks = followData.content ?? [];
        reply = followBlocks.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
        toolBlocks = [...toolBlocks, ...followBlocks.filter((b) => b.type === "tool_use")];
      }
    }

    // The model occasionally returns whitespace-only content with no tool calls —
    // never surface an empty bubble. One retry, then an honest fallback line.
    if (!reply && toolBlocks.length === 0) {
      console.error("empty completion", JSON.stringify({ stop_reason: data.stop_reason, usage: data.usage }));
      const retry = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({
          model: MODEL,
          ...SAMPLING,
          system,
          ...(oneShot ? {} : { tools: TOOLS }),
          messages: anthropicMessages,
        }),
      });
      if (retry.ok) {
        const retryData = await retry.json();
        const retryBlocks: typeof blocks = retryData.content ?? [];
        reply = retryBlocks.filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
        toolBlocks = retryBlocks.filter((b) => b.type === "tool_use");
      }
      // Not for a one-shot read: the app caches a block review in goals.review and a takeaway
      // in runs.coach_takeaway, and a cached "lost my train of thought" would stand in for
      // the retrospective, or that run's read, forever (#137). An empty reply is what tells
      // the app to cache nothing and ask again next time.
      if (!reply && toolBlocks.length === 0 && !oneShot) {
        reply = "Lost my train of thought there — ask me that again.";
      }
    }

    // The model occasionally omits `summary` despite the schema — guarantee it here,
    // since the app renders it on the confirm card.
    const proposed_actions = toolBlocks.map((b) => {
      const input = (b.input ?? {}) as Record<string, unknown>;
      const summary = (input.summary as string) ||
        ((input.note as string) ?? "").split(/(?<=\.)\s/)[0] ||
        `Proposed ${b.name}`;
      return { type: b.name, ...input, summary };
    });

    return Response.json({
      reply: reply || (proposed_actions.length > 0 ? "Here's what I'll change — confirm below." : ""),
      proposed_actions: proposed_actions.length > 0 ? proposed_actions : undefined,
    });
  } catch (err) {
    console.error("coach error", err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
