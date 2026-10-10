import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(new URL("../src/worker.js", import.meta.url), "utf8");
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

for (const [shortcut, target] of [
  ["/discord", "https://discord.gg/YkXnmB8rcF"],
  ["/github", "https://github.com/brandomoore/Plozz"],
]) {
  test(`${shortcut} redirects to its fixed target without forwarding query parameters`, async () => {
    for (const suffix of ["", "/", "?utm_source=website", "/?next=https://example.com"]) {
      for (const method of ["GET", "HEAD"]) {
        const response = await worker.fetch(new Request(`https://plozz.app${shortcut}${suffix}`, { method }));
        assert.equal(response.status, 302);
        assert.equal(response.headers.get("location"), target);
        assert.equal(response.headers.get("cache-control"), "no-store");
        assert.equal(response.headers.get("referrer-policy"), "no-referrer");
        assert.equal(await response.text(), "");
      }
    }
  });

  test(`${shortcut} route wildcard leaves similarly prefixed pages with the origin`, async (t) => {
    const originResponse = new Response("Origin content");
    const origin = t.mock.method(globalThis, "fetch", async () => originResponse);
    for (const suffix of ["-help", "/guide?source=website"]) {
      const request = new Request(`https://plozz.app${shortcut}${suffix}`);
      assert.equal(await worker.fetch(request), originResponse);
      assert.equal(origin.mock.calls.at(-1).arguments[0], request);
    }
    assert.equal(origin.mock.callCount(), 2);
  });
}

test("AASA retains pairing and verifies native HTTPS authentication", async () => {
  const response = await worker.fetch(new Request("https://plozz.app/.well-known/apple-app-site-association"));
  const aasa = await response.json();
  assert.deepEqual(aasa.applinks.details[0].paths, ["/pair", "/pair/*"]);
  assert.deepEqual(aasa.webcredentials.apps, ["N8Z5T4AK3X.com.thatcube.Plozz"]);
});

test("OAuth fallback never reflects a code or state and prevents caching/referrers", async () => {
  const response = await worker.fetch(new Request("https://plozz.app/auth/trakt/callback?code=secret-code&state=secret-state"));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("referrer-policy"), "no-referrer");
  const body = await response.text();
  assert.ok(!body.includes("secret-code"));
  assert.ok(!body.includes("secret-state"));
});

test("The worker does not claim unrelated pages", async () => {
  assert.equal((await worker.fetch(new Request("https://plozz.app/unrelated"))).status, 404);
  assert.equal((await worker.fetch(new Request("https://plozz.app/pair"))).status, 200);
});
