import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(new URL("../src/worker.js", import.meta.url), "utf8");
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);

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
