import { assert, assertEquals } from "jsr:@std/assert@^1";
import { isSilent, oneCardOnly, surplusCards, toolsForTurn } from "./proposals.ts";

const onboarding = { onboarding: { active: true } };
const chat = {};
const use = (id: string, name: string) => ({ type: "tool_use", id, name, input: {} });
const named = (...names: string[]) => names.map((name) => ({ name }));
const ALL = named("create_plan", "update_session", "remember", "update_athlete", "complete_onboarding");

Deno.test("one card: a reply with several shows the one that matters most", () => {
  const blocks = [use("a", "remember"), use("b", "update_session"), use("c", "remember")];
  assertEquals(oneCardOnly(blocks, chat).map((b) => b.id), ["b"]);
  assertEquals([...surplusCards(blocks, chat).keys()], ["a", "c"]);
});

Deno.test("one card: same rank, the first one stays", () => {
  const blocks = [use("a", "remember"), use("b", "remember"), use("c", "remember")];
  assertEquals(oneCardOnly(blocks, chat).map((b) => b.id), ["a"]);
});

Deno.test("one card: a single card has nothing surplus", () => {
  assertEquals(surplusCards([use("a", "amend_run")], chat).size, 0);
});

Deno.test("one card: text blocks are not cards", () => {
  const blocks = [{ type: "text", text: "Here." }, use("a", "remember")];
  assertEquals(surplusCards(blocks, chat).size, 0);
  assertEquals(oneCardOnly(blocks, chat).map((b) => b.type), ["tool_use"]);
});

Deno.test("one card: the surplus error names the card on screen and asks for a rewrite", () => {
  const why = surplusCards([use("a", "create_plan"), use("b", "remember")], chat).get("b") ?? "";
  assert(why.includes("create_plan"), why);
  assert(why.includes("write your reply again"), why);
});

Deno.test("onboarding: silent writes do not count against the one card, and all of them land", () => {
  const blocks = [
    use("a", "update_athlete"),
    use("b", "remember"),
    use("c", "create_plan"),
    use("d", "complete_onboarding"),
  ];
  assertEquals(surplusCards(blocks, onboarding).size, 0);
  assertEquals(oneCardOnly(blocks, onboarding).map((b) => b.id), ["a", "b", "c", "d"]);
});

Deno.test("onboarding: the same tools are ordinary cards once setup is over", () => {
  assert(isSilent("remember", onboarding));
  assert(!isSilent("remember", chat));
  const blocks = [use("a", "update_athlete"), use("b", "remember")];
  assertEquals(oneCardOnly(blocks, chat).map((b) => b.id), ["a"]);
});

Deno.test("complete_onboarding is only on offer during onboarding", () => {
  const names = (context: unknown, ack = false) => toolsForTurn(ALL, context, ack).map((t) => t.name);
  assert(names(onboarding).includes("complete_onboarding"));
  assert(!names(chat).includes("complete_onboarding"));
});

Deno.test("complete_onboarding outside onboarding never reaches the app, even if the model calls it", () => {
  const blocks = [use("a", "complete_onboarding"), use("b", "remember")];
  assertEquals(oneCardOnly(blocks, chat).map((b) => b.id), ["b"]);
  assertEquals(oneCardOnly([use("a", "complete_onboarding")], chat), []);
});

Deno.test("acknowledging a tap: no card tools, so the change just answered cannot come back", () => {
  assertEquals(toolsForTurn(ALL, chat, true), []);
});

Deno.test("acknowledging a tap during the interview: it can still record and finish, not propose", () => {
  assertEquals(
    toolsForTurn(ALL, onboarding, true).map((t) => t.name),
    ["remember", "update_athlete", "complete_onboarding"],
  );
});
