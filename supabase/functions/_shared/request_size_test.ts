import { assert, assertEquals } from "jsr:@std/assert@^1";
import {
  MAX_REQUEST_BYTES,
  promptBytes,
  readBodyWithin,
  TOO_LARGE_MESSAGE,
  tooLargeResponse,
} from "./request_size.ts";

const URL_ = "http://coach.test/";

function posted(body: string): Request {
  return new Request(URL_, { method: "POST", body });
}

/** A chunked request: no Content-Length, and `cancelled` says whether reading stopped early. */
function streamed(chunks: Uint8Array[]): { req: Request; cancelled: () => boolean; pulled: () => number } {
  let cancelled = false;
  let pulled = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (pulled === chunks.length) return controller.close();
      controller.enqueue(chunks[pulled++]);
    },
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  return {
    req: new Request(URL_, { method: "POST", body: stream }),
    cancelled: () => cancelled,
    pulled: () => pulled,
  };
}

Deno.test("a body under the limit comes back as it was sent", async () => {
  const body = JSON.stringify({ messages: [{ role: "user", content: "How was Tuesday's tempo? é 🏃" }] });
  assertEquals(await readBodyWithin(posted(body), 1024), body);
});

Deno.test("the limit is inclusive, and one byte past it is refused", async () => {
  assertEquals(await readBodyWithin(posted("x".repeat(100)), 100), "x".repeat(100));
  assertEquals(await readBodyWithin(posted("x".repeat(101)), 100), null);
});

Deno.test("the limit counts bytes, not characters", async () => {
  // 60 characters, 240 bytes: a limit on `.length` would let this through.
  assertEquals(await readBodyWithin(posted("🏃".repeat(30)), 100), null);
});

Deno.test("no body reads as empty, which the handler goes on to reject as it always has", async () => {
  assertEquals(await readBodyWithin(new Request(URL_, { method: "POST" }), 100), "");
});

Deno.test("a chunked body is reassembled in order, across a split character", async () => {
  const bytes = new TextEncoder().encode("pace 🏃 7:05");
  const { req } = streamed([bytes.slice(0, 7), bytes.slice(7)]);
  assertEquals(await readBodyWithin(req, 100), "pace 🏃 7:05");
});

Deno.test("a chunked body with no Content-Length is cut off once it passes the limit", async () => {
  const chunk = new Uint8Array(60);
  const { req, cancelled, pulled } = streamed([chunk, chunk, chunk, chunk, chunk]);
  assertEquals(await readBodyWithin(req, 100), null);
  assert(cancelled(), "the rest of the upload should be abandoned");
  assert(pulled() < 5, "reading should stop at the limit, not at the end");
});

Deno.test("a Content-Length that understates the body doesn't get it past the limit", async () => {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(500));
      controller.close();
    },
  });
  const req = new Request(URL_, { method: "POST", body: stream, headers: { "content-length": "10" } });
  assertEquals(await readBodyWithin(req, 100), null);
});

Deno.test("a Content-Length over the limit is refused without reading the body", async () => {
  const { req, pulled } = streamed([new Uint8Array(10)]);
  const declared = new Request(req, { headers: { "content-length": "101" } });
  assertEquals(await readBodyWithin(declared, 100), null);
  assertEquals(pulled(), 0);
});

Deno.test("a Content-Length that isn't a number falls through to counting", async () => {
  const req = new Request(URL_, { method: "POST", body: "short", headers: { "content-length": "lots" } });
  assertEquals(await readBodyWithin(req, 100), "short");
});

Deno.test("prompt size is the system prompt plus the messages as they go on the wire, in bytes", () => {
  const messages = [{ role: "user", content: "é" }];
  const wire = new TextEncoder().encode(JSON.stringify(messages)).length;
  assertEquals(promptBytes("🏃", messages), 4 + wire);
});

Deno.test("nesting that fits the body limit can't fit the prompt limit", () => {
  // Why the prompt is measured at all: this body is tiny, and it's the coach's own
  // `JSON.stringify(context, null, 1)` that makes it enormous.
  const depth = 2000;
  const body = `${"[".repeat(depth)}${"]".repeat(depth)}`;
  assert(body.length < MAX_REQUEST_BYTES.plan);
  const rendered = JSON.stringify(JSON.parse(body), null, 1);
  assert(promptBytes(rendered, []) > MAX_REQUEST_BYTES.coach);
});

Deno.test("the words can't be read as an outage or as lost data", () => {
  for (const [fn, message] of Object.entries(TOO_LARGE_MESSAGE)) {
    const words = message.toLowerCase();
    for (const word of ["unreachable", "couldn't", "failed", "offline", "lost"]) {
      assert(!words.includes(word), `${fn}: ${word}`);
    }
  }
});

Deno.test("the refusal is a 413 the app can recognize by name, and carries no Retry-After", async () => {
  const res = tooLargeResponse("coach");
  assertEquals(res.status, 413);
  // Waiting doesn't shrink a request, so nothing should tell a client to wait and resend it.
  assertEquals(res.headers.get("Retry-After"), null);
  assertEquals(await res.json(), { error: "request_too_large", message: TOO_LARGE_MESSAGE.coach });
});
