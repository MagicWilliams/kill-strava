// #184: the coach's create_plan enum and the plan engine's distance table must agree. A label
// the coach may send but /plan can't resolve is a confirm card that can only ever fail.

import { assertEquals } from "jsr:@std/assert@^1";
import { DISTANCES, namedDistance } from "../plan/generator.ts";
import { RACE_DISTANCES } from "./distances.ts";

Deno.test("#184: create_plan offers exactly the plan engine's distances, plus custom", () => {
  assertEquals(RACE_DISTANCES, [...Object.keys(DISTANCES), "custom"]);
});

Deno.test("#184: every label but custom resolves on its own; custom needs metres", () => {
  for (const d of RACE_DISTANCES.filter((d) => d !== "custom")) {
    assertEquals(namedDistance(d, undefined)?.label, d, d);
  }
  assertEquals(namedDistance("custom", undefined), null);
  assertEquals(namedDistance("custom", 8000)?.meters, 8000);
});
