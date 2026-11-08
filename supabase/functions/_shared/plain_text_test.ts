import { assertEquals } from "jsr:@std/assert@1";
import { cleanAction, cleanCoachTurns, stripDashes } from "./plain_text.ts";

const EM = "—";
const EN = "–";

Deno.test("a dash before a fragment becomes a comma", () => {
  assertEquals(
    stripDashes(`Five miles at 9:40 ${EM} hard for an easy day.`),
    "Five miles at 9:40, hard for an easy day.",
  );
});

Deno.test("a dash before a new clause ends the sentence", () => {
  assertEquals(stripDashes(`Good ${EM} that matches the plan.`), "Good. That matches the plan.");
  assertEquals(stripDashes(`Good ${EM} it's on the card.`), "Good. It's on the card.");
  assertEquals(stripDashes(`Done ${EM} I moved it.`), "Done. I moved it.");
});

Deno.test("a curly apostrophe still counts as a clause opener", () => {
  assertEquals(stripDashes(`Good ${EM} that’s the plan.`), "Good. That’s the plan.");
});

Deno.test("a dash before a capital ends the sentence", () => {
  assertEquals(stripDashes(`Two cards up ${EM} Friday is easy.`), "Two cards up. Friday is easy.");
});

Deno.test("a pair of dashes becomes a pair of commas", () => {
  assertEquals(
    stripDashes(`Once they confirm ${EM} it was their call ${EM} commit.`),
    "Once they confirm, it was their call, commit.",
  );
});

Deno.test("a pair is judged per sentence, not per message", () => {
  assertEquals(
    stripDashes(`Good ${EM} that works. Easy today ${EM} no pace target.`),
    "Good. That works. Easy today, no pace target.",
  );
});

Deno.test("an unspaced dash is treated the same as a spaced one", () => {
  assertEquals(stripDashes(`Easy today${EM}no pace target.`), "Easy today, no pace target.");
});

Deno.test("a dash between numbers becomes a range", () => {
  assertEquals(stripDashes(`Run 8:30 ${EM} 9:00 pace.`), `Run 8:30${EN}9:00 pace.`);
  assertEquals(stripDashes(`Do 5${EM}10 strides.`), `Do 5${EN}10 strides.`);
});

Deno.test("a trailing dash finishes the sentence", () => {
  assertEquals(stripDashes(`Good ${EM}`), "Good.");
  assertEquals(stripDashes(`Done. ${EM}`), "Done.");
  assertEquals(stripDashes(`Good ${EM}\nNext line.`), "Good.\nNext line.");
});

Deno.test("a dash at the start of a line is removed", () => {
  assertEquals(stripDashes(`${EM} first\n${EM} second`), "first\nsecond");
});

Deno.test("a dash after punctuation does not double it", () => {
  assertEquals(stripDashes(`Done, ${EM} moved it.`), "Done, moved it.");
  assertEquals(stripDashes(`Done. ${EM} Next week is easy.`), "Done. Next week is easy.");
});

Deno.test("a dash closing a quote or bracket is dropped", () => {
  assertEquals(stripDashes(`(easy ${EM})`), "(easy)");
});

Deno.test("the horizontal bar is treated as an em dash", () => {
  assertEquals(stripDashes("Easy today ― no pace."), "Easy today, no pace.");
});

Deno.test("stand-ins for an em dash are caught", () => {
  assertEquals(stripDashes(`Easy today ${EN} no pace.`), "Easy today, no pace.");
  assertEquals(stripDashes("Easy today - no pace."), "Easy today, no pace.");
  assertEquals(stripDashes("Easy today -- no pace."), "Easy today, no pace.");
  assertEquals(stripDashes("Easy today--no pace."), "Easy today, no pace.");
});

Deno.test("ranges, hyphenated words and bullets are left alone", () => {
  for (
    const text of [
      `RPE 1${EN}10`,
      `8:30 ${EN} 9:00 pace`,
      `5K ${EN} 10K range`,
      "5K - 10K range",
      "8:30 - 9:00 pace",
      "a well-run tempo",
      "a 20-miler",
      "- first\n- second",
      "HR 175 at 3:15:00 on 2026-11-04",
      "Correct Tue's run: 6.0 → 8.0 mi",
    ]
  ) {
    assertEquals(stripDashes(text), text);
  }
});

Deno.test("paragraph breaks survive", () => {
  assertEquals(
    stripDashes(`First ${EM} a note.\n\nSecond paragraph.`),
    "First, a note.\n\nSecond paragraph.",
  );
});

Deno.test("text with no dash comes back unchanged", () => {
  assertEquals(stripDashes(""), "");
  assertEquals(stripDashes("  Keep it easy.  "), "  Keep it easy.  ");
});

Deno.test("no input leaves an em dash behind", () => {
  for (
    const text of [
      `${EM}`,
      `${EM}${EM}`,
      `a ${EM}${EM} b`,
      `${EM} a ${EM} b ${EM} c ${EM}`,
      `"quoted ${EM}" and (bracket ${EM}) and 5${EM}`,
    ]
  ) {
    assertEquals(stripDashes(text).includes(EM), false, text);
  }
});

Deno.test("cleanAction cleans prose fields and leaves data alone", () => {
  const action = {
    type: "update_session",
    session_id: `id${EM}1`,
    race_name: `Run ${EM} Fest`,
    target_pace_sec: 540,
    summary: `Move the long run ${EM} easy effort`,
    note: `Moved ${EM} the athlete asked`,
    detail: `4 mi ${EM} relaxed`,
  };
  assertEquals(cleanAction(action), {
    type: "update_session",
    session_id: `id${EM}1`,
    race_name: `Run ${EM} Fest`,
    target_pace_sec: 540,
    summary: "Move the long run, easy effort",
    note: "Moved, the athlete asked",
    detail: "4 mi, relaxed",
  });
});

Deno.test("cleanCoachTurns touches only the coach's turns", () => {
  const turns = [
    { role: "user", content: `My words ${EM} keep them` },
    { role: "assistant", content: `Easy today ${EM} no pace.` },
  ];
  assertEquals(cleanCoachTurns(turns), [
    { role: "user", content: `My words ${EM} keep them` },
    { role: "assistant", content: "Easy today, no pace." },
  ]);
});
