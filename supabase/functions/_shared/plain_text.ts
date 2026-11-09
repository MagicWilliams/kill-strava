// Removes dashes from model-written text before anyone reads it (#264).
//
// Telling the model not to use em dashes helps but does not hold: 80% of stored coach messages
// carried one, and a model told to stop tends to reach for " - " or " – " instead. So the rule
// is enforced here, on every sentence leaving the function, the same way goal_guard.ts enforces
// goal times rather than trusting the prompt.
//
// Banned WORDS stay a prompt rule on purpose. Swapping a word in a finished sentence produces
// garbage; a dash can nearly always be replaced by a comma or a period.

const DASH = "—";

/// Words that open a new clause. A dash before one of these was joining two sentences, so a
/// comma there would be a comma splice: "Good, that matches" should be "Good. That matches".
const CLAUSE_OPENERS = new Set([
  "that", "that's", "this", "it", "it's", "i", "i'm", "i'd", "i'll", "i've", "we", "we're",
  "we'll", "you", "you're", "you've", "you'll", "they", "they're", "there", "there's", "here",
  "here's",
]);

const LETTER = /^\p{L}/u;
const UPPERCASE = /^\p{Lu}/u;

/// True when this dash is half of a pair inside one sentence: "the run, a hard one, went well".
/// Both halves must become commas, or the first one would end the sentence mid-thought.
function isPaired(text: string, start: number, end: number): boolean {
  const sentenceStart = Math.max(
    text.lastIndexOf(". ", start),
    text.lastIndexOf("? ", start),
    text.lastIndexOf("! ", start),
    text.lastIndexOf("\n", start),
  );
  const afterStops = [". ", "? ", "! ", "\n"]
    .map((stop) => text.indexOf(stop, end))
    .filter((index) => index >= 0);
  const sentenceEnd = afterStops.length > 0 ? Math.min(...afterStops) : text.length;
  return text.slice(sentenceStart + 1, start).includes(DASH) ||
    text.slice(end, sentenceEnd).includes(DASH);
}

function replaceDash(whole: string, start: number, end: number): string {
  const before = whole.slice(0, start);
  const after = whole.slice(end);
  const last = before.slice(-1);
  const next = after.slice(0, 1);

  // Alone at the start of a line, used as a bullet.
  if (before === "" || last === "\n") return "";
  // Trailing off: "Good —" reads as a finished thought.
  if (after === "" || next === "\n") return /[.,;:!?…]/.test(last) ? "" : ".";
  // A range the model wrote with the wrong dash. The en dash is how ranges read everywhere else.
  if (/\d/.test(last) && /\d/.test(next)) return "–";
  // Already punctuated, or closing a quote or bracket straight after the dash.
  if (/[.,;:!?…]/.test(last)) return " ";
  if (/[)\]"'”’]/.test(next)) return "";

  if (isPaired(whole, start, end)) return ", ";

  const word = (after.match(/^[\p{L}'’]+/u)?.[0] ?? "").replace("’", "'").toLowerCase();
  if (UPPERCASE.test(next)) return ". ";
  if (LETTER.test(next) && CLAUSE_OPENERS.has(word)) return `. ${next.toUpperCase()}`;
  return ", ";
}

/// The text with every em dash replaced, and en dashes or hyphens used as em dashes along with
/// them. Ranges ("1–10", "8:30 – 9:00"), hyphenated words and list bullets are left alone.
export function stripDashes(text: string): string {
  const normalized = text
    .replace(/―/g, DASH)
    // Stand-ins a model uses when told not to write an em dash. A digit after the mark means a
    // range ("5K – 10K"), and a line-start hyphen is a bullet, so both are excluded.
    .replace(/(?<=\S)[ \t]+(?:--|–)[ \t]+(?=\p{L})/gu, ` ${DASH} `)
    .replace(/(?<=\p{L})[ \t]+-[ \t]+(?=\p{L})/gu, ` ${DASH} `)
    .replace(/(?<=\p{L})--(?=\p{L})/gu, DASH);

  let out = "";
  let cursor = 0;
  for (const match of normalized.matchAll(/[ \t]*—+[ \t]*/g)) {
    const start = match.index;
    const end = start + match[0].length;
    const replacement = replaceDash(normalized, start, end);
    out += normalized.slice(cursor, start) + replacement;
    cursor = end;
    // An opener was re-cased inside the replacement, so its first letter is already written.
    if (replacement.length === 3 && LETTER.test(replacement.slice(2))) cursor += 1;
  }
  return out + normalized.slice(cursor);
}

/// The fields of a proposed action that a person reads. Everything else on an action is data
/// (ids, dates, clock strings, the athlete's race name) and must reach the app untouched.
const PROSE_FIELDS = [
  "summary", "note", "rationale", "fact", "detail", "title", "risk_named", "reason",
  "injury_notes", "strength_notes",
];

/// A proposed action with its prose cleaned and its data unchanged.
export function cleanAction<T extends Record<string, unknown>>(action: T): T {
  const out: Record<string, unknown> = { ...action };
  for (const field of PROSE_FIELDS) {
    if (typeof out[field] === "string") out[field] = stripDashes(out[field] as string);
  }
  return out as T;
}

/// The prose a model proposed for a plan, cleaned (#265). Only the two fields an athlete reads
/// are touched: the rationale shown beside the projection, and each phase's focus line, which
/// the generator copies onto every week that phase covers. Everything else on a shape is data
/// the generator does arithmetic on (week counts, volumes, the phase name the CHECK admits),
/// and a comma spliced into one of those would be a corrupted plan, not a style fix.
///
/// Shaped structurally rather than by importing plan's `Shape`: this runs on whatever the model
/// put in the tool call, so a field it left out is something to pass through, not to throw on.
export function cleanShape<T extends { rationale?: string; phases?: { focus?: string }[] }>(
  shape: T,
): T {
  const out: Record<string, unknown> = { ...shape };
  if (typeof shape.rationale === "string") out.rationale = stripDashes(shape.rationale);
  if (Array.isArray(shape.phases)) {
    out.phases = shape.phases.map((phase) =>
      phase && typeof phase.focus === "string" ? { ...phase, focus: stripDashes(phase.focus) } : phase
    );
  }
  return out as T;
}

/// The transcript with the coach's own past turns cleaned, so the model is not shown its old
/// style to copy. The athlete's turns are their words and pass through as written.
export function cleanCoachTurns<T extends { role: string; content: string }>(turns: readonly T[]): T[] {
  return turns.map((turn) =>
    turn.role === "assistant" ? { ...turn, content: stripDashes(turn.content) } : turn
  );
}
