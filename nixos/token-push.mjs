// workhorse-token-push — keeps the Workhorse Worker supplied with a fresh
// short-lived Anthropic OAuth ACCESS token.
//
// The MacBook is the sole custodian of the REFRESH token (Pi auto-refreshes
// ~/.pi/agent/auth.json). This script runs on a systemd timer:
//   1. Read the pi-runner's auth.json.
//   2. If the access token expires soon, run a tiny Pi call to force refresh.
//   3. POST the access token to the Worker (stored in KV; sandboxes get it
//      injected per run). Push model — no public minting endpoint exists.
//
// Env: WORKHORSE_URL, WORKHORSE_TOKEN (bearer), HOME (pi-runner's home).

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const HOME = process.env.HOME || "/var/lib/pi-runner";
const AUTH = join(HOME, ".pi", "agent", "auth.json");
const PI_CLI = join(HOME, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
const URL_BASE = process.env.WORKHORSE_URL || "https://workhorse-sandbox.stevenjpx2.workers.dev";
const MIN_LEFT_MS = 90 * 60 * 1000; // refresh when < 90 min of life left

function readAuth() {
  return JSON.parse(readFileSync(AUTH, "utf8")).anthropic;
}

let a = readAuth();
if ((a.expires ?? 0) - Date.now() < MIN_LEFT_MS) {
  // Force Pi to refresh the token (in-process OAuth refresh, no browser).
  console.log("access token stale; forcing refresh via tiny pi call");
  try {
    execFileSync(process.execPath, [PI_CLI, "-p", "-np", "Reply with: ok"], {
      env: { ...process.env, HOME },
      timeout: 120_000,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (e) {
    console.error("refresh call failed (continuing with current token):", e.message);
  }
  a = readAuth();
}

const token = process.env.WORKHORSE_TOKEN;
if (!token) throw new Error("WORKHORSE_TOKEN not set");

const res = await fetch(`${URL_BASE}/token`, {
  method: "POST",
  headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  body: JSON.stringify({ access: a.access, expires: a.expires }),
});
if (!res.ok) throw new Error(`push failed: ${res.status} ${await res.text()}`);
console.log(`pushed access token (expires ${new Date(a.expires).toISOString()})`);
