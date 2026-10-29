// The thread write-up either parses cleanly or does not exist (#87).
//
// Pinned here because the cost of a half-parse is silent and long-lived: `coach_threads.title`
// and `.summary` are written once and then shown on the Coach tab and fed to the next
// conversation as "Picking up from". A summary of `"null"`, or a recap that is really a code
// fence, would read as a real recap of a conversation that said something else.

import { assertEquals } from "jsr:@std/assert@^1";
import { parseThreadSummary, SUMMARY_LIMIT, TITLE_LIMIT } from "./summary.ts";

Deno.test("bare JSON, the shape the prompt asks for", () => {
  assertEquals(
    parseThreadSummary(
      '{"title":"Race-week shakeout and the calf","summary":"Calf tight after Tuesday\'s strides. Thursday\'s tempo became an easy 5."}',
    ),
    {
      title: "Race-week shakeout and the calf",
      summary: "Calf tight after Tuesday's strides. Thursday's tempo became an easy 5.",
    },
  );
});

Deno.test("a fenced block is unwrapped rather than wasting a second round trip", () => {
  const reply = '```json\n{"title":"Pacing Chicago","summary":"Settled on 7:25 through 20."}\n```';
  assertEquals(parseThreadSummary(reply), {
    title: "Pacing Chicago",
    summary: "Settled on 7:25 through 20.",
  });
});

Deno.test("a leading line of prose is stepped over", () => {
  const reply = 'Here is the summary:\n\n{"title":"Missing September runs","summary":"Recorded in Strava, never reached Health."}';
  assertEquals(parseThreadSummary(reply), {
    title: "Missing September runs",
    summary: "Recorded in Strava, never reached Health.",
  });
});

Deno.test("newlines inside the recap collapse to one line", () => {
  assertEquals(
    parseThreadSummary('{"title":"The calf","summary":"Tight after strides.\\n\\nWatching it."}')?.summary,
    "Tight after strides. Watching it.",
  );
});

Deno.test("an over-long title is clipped on a word boundary, never mid-word", () => {
  const long = "Race-week shakeout, the calf, Thursday's tempo, Saturday's easy five and the taper itself";
  const parsed = parseThreadSummary(JSON.stringify({ title: long, summary: "ok" }));
  assertEquals(parsed!.title.length <= TITLE_LIMIT + 1, true);
  assertEquals(parsed!.title.endsWith("…"), true);
  assertEquals(parsed!.title.includes(" …"), false, "the trailing space goes with the clip");
  assertEquals(long.startsWith(parsed!.title.slice(0, -1)), true, "nothing invented, only cut");
});

Deno.test("an over-long summary is clipped too", () => {
  const long = "x".repeat(50) + " " + "y".repeat(400);
  const parsed = parseThreadSummary(JSON.stringify({ title: "Long one", summary: long }));
  assertEquals(parsed!.summary.length <= SUMMARY_LIMIT + 1, true);
});

Deno.test("nothing half-parsed is ever returned", () => {
  for (
    const reply of [
      null,
      undefined,
      "",
      "   ",
      "Lost my train of thought there — ask me that again.",
      "{}",
      "[]",
      '{"title":"Only a title"}',
      '{"summary":"Only a summary"}',
      '{"title":"","summary":"empty title"}',
      '{"title":"   ","summary":"whitespace title"}',
      '{"title":"ok","summary":""}',
      '{"title":null,"summary":null}',
      '{"title":7,"summary":9}',
      '{"title":{"a":1},"summary":"object title"}',
      '"a bare string"',
      "null",
    ]
  ) {
    assertEquals(parseThreadSummary(reply), null, `expected no summary from ${JSON.stringify(reply)}`);
  }
});

Deno.test("extra keys the model volunteers are ignored, not rejected", () => {
  assertEquals(
    parseThreadSummary('{"title":"Shoes","summary":"New pair logged; the old ones are retired.","tags":["gear"],"confidence":0.8}'),
    { title: "Shoes", summary: "New pair logged; the old ones are retired." },
  );
});
