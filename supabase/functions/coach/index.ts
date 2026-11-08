// Tempo coach — Claude behind a Supabase Edge Function.
// The app sends chat history + a compact snapshot of real training data
// (recent runs with ids, weekly mileage, goal, risk tolerance); the Anthropic
// key never leaves the server.
//
// Write path: the coach PROPOSES actions via tool calls (amend_run / add_run /
// set_risk_tolerance). The function never writes to the DB — proposals are
// returned to the app, which renders a confirm card and executes the write
// client-side under RLS after the athlete confirms. `remember` is the same deal
// for a durable fact (#87): the card is the athlete's consent, the app writes it.
//
// Modes: no mode is a chat turn. `takeaway` reads one run, `block_review` one
// training block, and `summarize` writes up a finished thread as {title, summary}
// (#87) — all three one-shot, no tools, nothing persisted here.

import { sanitizeHistory, type WireMessage } from "./history.ts";
import { runEditing, shapeRunInput, speaksRunFacts } from "./run_corrections.ts";
import { goalLifecycle } from "./goal_lifecycle.ts";
import { parseThreadSummary } from "./summary.ts";
import { goalRejections, HELD_BACK_PLAN } from "./goal_guard.ts";
import { ACKNOWLEDGE_RULES, isSilent, oneCardOnly, surplusCards, toolsForTurn } from "./proposals.ts";
import { usageRefusal } from "../_shared/usage_gate.ts";
import { usageKindForMode } from "../_shared/usage_limit.ts";
import { cleanAction, cleanCoachTurns, stripDashes } from "../_shared/plain_text.ts";
import {
  BLOCK_REVIEW_INSTRUCTIONS,
  CONFIRM_BELOW_REPLY,
  LOST_THREAD_REPLY,
  OTHER_TOOLS,
  persona,
  SUMMARIZE_INSTRUCTIONS,
  TAKEAWAY_INSTRUCTIONS,
  TOOL_RESULT_PROPOSED,
  TOOL_RESULT_RECORDED,
} from "./prompts.ts";

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

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "POST only" }, { status: 405 });
  }

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) {
    return Response.json({ error: "ANTHROPIC_API_KEY not configured" }, { status: 500 });
  }

  try {
    const { messages, context, mode, run, block, features, acknowledging } = await req.json();

    // #206: a build that computes run corrections itself says so in `features`; anything
    // else (every build installed before it) keeps the totals schema it was written against.
    const facts = speaksRunFacts(features);
    const runTools = runEditing(features);
    // #238: end_goal only for a build that can apply it, the same handshake as run_facts.
    const goalTools = goalLifecycle(features);
    // Only ever true from a build that sends it. Every other caller gets the whole set.
    const TOOLS = toolsForTurn(
      [...runTools.tools, ...OTHER_TOOLS, ...goalTools.tools],
      context,
      acknowledging === true,
    );
    // An empty list is refused by the API, and "no tools" is what an acknowledgement means.
    const toolsParam = TOOLS.length > 0 ? { tools: TOOLS } : {};

    // Takeaway mode: one-shot per-run read, cached by the app in runs.coach_takeaway.
    // Block review mode: one-shot block retrospective, cached by the app in goals.review.
    // Summarize mode: one-shot thread write-up, stored by the app on coach_threads (#87).
    const takeaway = mode === "takeaway";
    const blockReview = mode === "block_review";
    const summarize = mode === "summarize";
    const oneShot = takeaway || blockReview || summarize;
    // Summarize is one-shot in that it carries no tools, but unlike the other two it has
    // nothing to say without a transcript: an empty thread must not reach Anthropic to come
    // back with a write-up of a conversation that never happened.
    if ((!oneShot || summarize) && (!Array.isArray(messages) || messages.length === 0)) {
      return Response.json({ error: "messages required" }, { status: 400 });
    }

    let system = `${persona(runTools.rules, goalTools.rules)}\n\n<athlete_context>\n${JSON.stringify(context ?? {}, null, 1)}\n</athlete_context>`;
    if (acknowledging === true) system += `\n\n${ACKNOWLEDGE_RULES}`;
    let wireMessages: WireMessage[] = messages ?? [];
    if (takeaway) {
      system += `\n\n<run_detail>\n${JSON.stringify(run ?? {}, null, 1)}\n</run_detail>`;
      wireMessages = [{ role: "user", content: TAKEAWAY_INSTRUCTIONS }];
    }
    if (blockReview) {
      system += `\n\n<block_review>\n${JSON.stringify(block ?? {}, null, 1)}\n</block_review>`;
      wireMessages = [{ role: "user", content: BLOCK_REVIEW_INSTRUCTIONS }];
    }
    // The transcript stays in place and the instruction goes in as the last user turn: the
    // thing being summarized IS the conversation, so it cannot be replaced by the prompt the
    // way a one-run read can.
    if (summarize) {
      wireMessages = [...wireMessages, { role: "user", content: SUMMARIZE_INSTRUCTIONS }];
    }

    // #193: Anthropic rejects the request outright if the array ends in an assistant turn,
    // and the client can only report that as an opaque 502. Done once, here, because all
    // three calls below (first round, tool continuation, empty-reply retry) rebuild the same
    // array — the continuation round appends its own assistant+user pair on top of it.
    const anthropicMessages = cleanCoachTurns(sanitizeHistory(wireMessages));
    if (anthropicMessages.length === 0) {
      return Response.json({ error: "history must end with a user turn" }, { status: 400 });
    }

    // Last thing before the money: a request refused above never counts against anyone, and
    // one refused here has spent nothing. One claim covers every round below, because a tool
    // continuation or an empty-reply retry is the same turn to the athlete.
    const refusal = await usageRefusal(req.headers.get("Authorization"), usageKindForMode(mode));
    if (refusal) return refusal;

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
        ...(oneShot ? {} : toolsParam),
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

    // #239: a pr/unsure create_plan whose goal_time_s the app's suggested_goal does not back
    // goes back to the model as a tool error, and its reply is rewritten in the round below.
    const athleteTurns = anthropicMessages.filter((m) => m.role === "user").map((m) => m.content);
    const rejected = goalRejections(toolBlocks, context, athleteTurns);
    // One proposal at a time, counted among the cards the guard let through. These go back the
    // same way: the text was written about all of them, so it gets rewritten too.
    const offered = toolBlocks.filter((b) => !rejected.has(b.id ?? ""));
    for (const [id, why] of surplusCards(offered, context)) rejected.set(id, why);

    // The model often emits ONLY a tool call, no prose — which would stall the
    // conversation (especially the onboarding interview). One continuation round:
    // feed back tool results and let the coach keep talking.
    if ((toolBlocks.length > 0 && !reply) || rejected.size > 0) {
      const toolResults = toolBlocks.map((b) => ({
        type: "tool_result",
        tool_use_id: b.id,
        ...(rejected.has(b.id ?? "") ? { is_error: true } : {}),
        content: rejected.get(b.id ?? "") ?? (isSilent(b.name, context)
          ? TOOL_RESULT_RECORDED
          : TOOL_RESULT_PROPOSED),
      }));
      const followUp = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({
          model: MODEL,
          ...SAMPLING,
          system,
          ...toolsParam,
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
        toolBlocks = [
          ...toolBlocks.filter((b) => !rejected.has(b.id ?? "")),
          ...followBlocks.filter((b) => b.type === "tool_use"),
        ];
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
          ...(oneShot ? {} : toolsParam),
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
        reply = LOST_THREAD_REPLY;
      }
    }

    // #239: whatever happened above, a card the guard rejects never reaches the athlete.
    const stillRejected = goalRejections(toolBlocks, context, athleteTurns);
    if (stillRejected.size > 0) {
      console.error("create_plan goal_time_s rejected twice", JSON.stringify([...stillRejected.values()]));
      toolBlocks = toolBlocks.filter((b) => !stillRejected.has(b.id ?? ""));
      reply = reply ? `${reply}\n\n${HELD_BACK_PLAN}` : HELD_BACK_PLAN;
    }

    // Whatever the rounds above produced, the app gets at most one card.
    toolBlocks = oneCardOnly(toolBlocks, context);

    // The model occasionally omits `summary` despite the schema — guarantee it here,
    // since the app renders it on the confirm card.
    const proposed_actions = toolBlocks.map((b) => {
      const input = (b.input ?? {}) as Record<string, unknown>;
      const summary = (input.summary as string) ||
        ((input.note as string) ?? "").split(/(?<=\.)\s/)[0] ||
        `Proposed ${b.name}`;
      return cleanAction({ type: b.name, ...shapeRunInput(b.name, input, facts), summary });
    });

    // A write-up is {title, summary} or nothing at all: `summary.ts` returns null for
    // anything half-parsed, and an empty object is what tells the app to leave the thread
    // unsummarized and ask again rather than store a recap it can't stand behind.
    if (summarize) {
      const written = parseThreadSummary(reply);
      return Response.json(
        written ? { title: stripDashes(written.title), summary: stripDashes(written.summary) } : {},
      );
    }

    return Response.json({
      reply: stripDashes(reply) || (proposed_actions.length > 0 ? CONFIRM_BELOW_REPLY : ""),
      proposed_actions: proposed_actions.length > 0 ? proposed_actions : undefined,
    });
  } catch (err) {
    console.error("coach error", err);
    return Response.json({ error: String(err) }, { status: 500 });
  }
});
