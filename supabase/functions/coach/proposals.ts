// What the coach may put in front of the athlete to confirm: one thing, and never the thing
// they just answered.
//
// Pure, for the same reason goal_guard.ts is: index.ts does the I/O, this decides, and every
// way it goes wrong is a screen full of plausible buttons rather than a crash.
//
// 2026-11-04, two fresh accounts going through setup:
// - A tap reaches the model as a user turn, "Confirmed: Correct Oct 27 run". With tools on
//   offer and no record of the card, the model read that as the athlete agreeing to a change
//   and proposed it. One run correction went up four times, "that card is up now" each time;
//   a complete_onboarding card went up five times.
// - One reply carried three memory cards, another a session change and a memory ("Two cards
//   up. Confirm both when ready.").
// - complete_onboarding was on offer after setup had ended, so it rendered as a card that did
//   nothing visible when confirmed.

/// Written without a card during the setup interview: the athlete's answer is the consent.
/// Mirrors `CoachAcknowledgement.onboardingAutoApplyTypes` in the app.
export const SILENT_DURING_ONBOARDING = new Set([
  "update_athlete",
  "update_plan_settings",
  "set_risk_tolerance",
  "complete_onboarding",
  "remember",
]);

/// When a reply carries several cards anyway, the one kept is the one that matters most to the
/// athlete's training. Mirrors `OpenProposal.rank` in the app. Anything unlisted ranks last.
const CARD_RANK = [
  "create_plan",
  "end_goal",
  "update_plan_settings",
  "update_session",
  "amend_run",
  "add_run",
  "set_risk_tolerance",
  "update_athlete",
  "remember",
];

interface Block {
  type: string;
  name?: string;
  id?: string;
  input?: Record<string, unknown>;
}

const inOnboarding = (context: unknown): boolean =>
  (context as { onboarding?: { active?: unknown } } | null | undefined)?.onboarding?.active === true;

/// Whether this tool writes without asking, on this turn.
export function isSilent(name: string | undefined, context: unknown): boolean {
  return inOnboarding(context) && SILENT_DURING_ONBOARDING.has(name ?? "");
}

const rank = (name: string | undefined): number => {
  const at = CARD_RANK.indexOf(name ?? "");
  return at === -1 ? CARD_RANK.length : at;
};

/// The tools this turn may call.
///
/// complete_onboarding only exists during onboarding. An acknowledgement (the app reporting a
/// tap) gets no card tools at all: a change the athlete just answered is the one thing it must
/// not propose, and a tool it does not have is the only rule the model cannot talk itself out
/// of. The silent tools stay, so the interview can still record an answer and finish.
export function toolsForTurn<T extends { name: string }>(
  tools: readonly T[],
  context: unknown,
  acknowledging: boolean,
): T[] {
  const available = tools.filter((t) => t.name !== "complete_onboarding" || inOnboarding(context));
  return acknowledging ? available.filter((t) => isSilent(t.name, context)) : available;
}

/// The one card this reply shows, or undefined when it has none. First wins a tie.
function keptCard(blocks: readonly Block[], context: unknown): Block | undefined {
  let kept: Block | undefined;
  for (const b of blocks) {
    if (b.type !== "tool_use" || isSilent(b.name, context)) continue;
    if (!kept || rank(b.name) < rank(kept.name)) kept = b;
  }
  return kept;
}

/// Cards past the one kept, by tool_use id, with the error the coach is shown. They go back to
/// the model rather than vanishing, because its text was written about all of them.
export function surplusCards(blocks: readonly Block[], context: unknown): Map<string, string> {
  const kept = keptCard(blocks, context);
  const surplus = new Map<string, string>();
  for (const b of blocks) {
    if (b.type !== "tool_use" || b === kept || !b.id || isSilent(b.name, context)) continue;
    surplus.set(
      b.id,
      `Not shown: the athlete sees one proposal at a time, and ${kept?.name} is the one on screen. The athlete has not seen your previous message: write your reply again from the start, about that card only. Say in words what you would raise next, and raise it after they have answered. Do not call another proposal tool this turn, and do not mention this check.`,
    );
  }
  return surplus;
}

/// The blocks that reach the app: every silent write, and at most one card. The last word,
/// after any continuation round, whatever the model did. complete_onboarding outside
/// onboarding is dropped here as well as withheld above: it has no card worth showing.
export function oneCardOnly<T extends Block>(blocks: readonly T[], context: unknown): T[] {
  const usable = blocks.filter((b) => b.name !== "complete_onboarding" || inOnboarding(context));
  const kept = keptCard(usable, context);
  return usable.filter((b) => b === kept || isSilent(b.name, context));
}

/// The rules every chat turn is given. In the prompt, not only enforced above, so the text the
/// model writes agrees with what ends up on screen.
export const PROPOSAL_RULES = `Proposing changes:
- The athlete's most recent word outranks everything else you hold: the intake form, your last proposal, memory, the data. When they correct a fact, the correction stands. Use their version, do not restate yours, and do not count it as a second data point. If they said something the data cannot see, believe them and reason from it.
- A proposal is what the athlete asked for, in your words. If you think it is a mistake, say so once in the message, and put their version on the card unless they accept yours.
- At most ONE proposal per message: one tool call that shows a card. If more than one change is worth making, propose the one that matters most and say in words what you would raise next. Never write "two cards" or "confirm both".
- Never mention a card unless you are calling its tool in this same message. Text alone puts nothing on screen.
- <athlete_context>.open_proposal is the card on screen right now, unanswered. It only stays open if you stand behind it after what the athlete just said: if you still mean it, call the tool again in this message with whatever they said folded in, and the new card replaces it. If you do not call it, the card closes on its own. So never leave a stale one up, and never re-propose it unchanged if what they said argues against it.
- <athlete_context>.applied_in_thread lists what has already been applied in this conversation. Those changes are done. Never propose one again.
- A user turn that is the word "Confirmed" or "Dismissed" followed by a card's summary is the app recording a button the athlete tapped, not something they said, and not agreement to anything new.`;

/// Added when the last turn is the app reporting a tap. The tools are already gone by then, so
/// this exists to keep the words honest.
export const ACKNOWLEDGE_RULES = `This turn is an acknowledgement. The last user turn is the app recording a button the athlete tapped; they have not said anything new. You cannot put a card up this turn, so do not say one is waiting.
- "Confirmed": it is applied, and <athlete_context> already reflects it. Say in one to three sentences what it means for them. If another change is worth making, describe it in words and ask.
- "Dismissed": nothing changed. Ask what they would rather do, in a sentence. Do not offer the same change again.`;
