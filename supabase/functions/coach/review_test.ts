// `parseWeeklyReview` against the replies a model actually sends (#91).
//
// Same contract as summary_test.ts: anything half-formed is null, because the app stores a
// whole review or stores nothing. A review is written once and read for months, so a section
// quietly missing from it has no second chance to be noticed.

import { assertEquals } from "jsr:@std/assert@^1";
import { HEADLINE_LIMIT, parseWeeklyReview, SECTION_LIMIT } from "./review.ts";

const WHOLE = {
  headline: "The taper did its job. You are carrying less fatigue than any week since July.",
  training: "Tuesday's strides were the sharpest of the block. Easy runs held the same pace at a lower heart rate than August.",
  plan_moved: "Race week was added Wednesday. Thursday's tempo became an easy 5 after you flagged the calf.",
  next_week: "Race Sunday. Then a week of nothing structured.",
};

Deno.test("a whole review parses", () => {
  assertEquals(parseWeeklyReview(JSON.stringify(WHOLE)), WHOLE);
});

Deno.test("a fenced reply parses, and so does one with a preface", () => {
  assertEquals(parseWeeklyReview("```json\n" + JSON.stringify(WHOLE) + "\n```"), WHOLE);
  assertEquals(parseWeeklyReview("Here is the review:\n" + JSON.stringify(WHOLE)), WHOLE);
});

Deno.test("a missing or empty section is no review at all", () => {
  for (const key of ["headline", "training", "plan_moved", "next_week"]) {
    const missing: Record<string, unknown> = { ...WHOLE };
    delete missing[key];
    assertEquals(parseWeeklyReview(JSON.stringify(missing)), null, `${key} missing`);

    assertEquals(parseWeeklyReview(JSON.stringify({ ...WHOLE, [key]: "   " })), null, `${key} blank`);
    assertEquals(parseWeeklyReview(JSON.stringify({ ...WHOLE, [key]: null })), null, `${key} null`);
    assertEquals(parseWeeklyReview(JSON.stringify({ ...WHOLE, [key]: 7 })), null, `${key} number`);
  }
});

Deno.test("nothing, prose and a JSON array are all null", () => {
  assertEquals(parseWeeklyReview(undefined), null);
  assertEquals(parseWeeklyReview(null), null);
  assertEquals(parseWeeklyReview(""), null);
  assertEquals(parseWeeklyReview("Good week. Keep it up."), null);
  assertEquals(parseWeeklyReview(JSON.stringify([WHOLE])), null);
});

Deno.test("an over-long headline and section are clipped on a word boundary, not mid-word", () => {
  const long = "running ".repeat(200).trim();
  const parsed = parseWeeklyReview(JSON.stringify({ ...WHOLE, headline: long, training: long }));
  if (!parsed) throw new Error("expected a review");
  assertEquals(parsed.headline.length <= HEADLINE_LIMIT + 1, true);
  assertEquals(parsed.training.length <= SECTION_LIMIT + 1, true);
  assertEquals(parsed.headline.endsWith("…"), true);
  assertEquals(parsed.headline.includes("runnin…"), false);
});

Deno.test("whitespace inside a section is collapsed, so the screen draws one paragraph", () => {
  const parsed = parseWeeklyReview(JSON.stringify({ ...WHOLE, next_week: "Race Sunday.\n\n  Then rest." }));
  assertEquals(parsed?.next_week, "Race Sunday. Then rest.");
});
