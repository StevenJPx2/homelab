// pi-runner — tiny HTTP wrapper around headless Pi for homelab-ops agent tickets.
//
// POST /run  {"ticket": "..."}  -> {"answer": "...", "ok": true, "ms": 1234}
// GET  /health                  -> {"ok": true, "loggedIn": <bool>}
//
// Runs `pi -p --mode json` as a subprocess, parses the JSONL event stream,
// and returns the final assistant text from the agent_end event.
//
// Auth: uses the Claude Pro/Max OAuth token in $HOME/.pi/agent/auth.json
// (written once via `pi /login anthropic`) plus the @gotgenes/pi-anthropic-auth
// extension. No API key. Bound to 127.0.0.1 — reachable only via localhost /
// Tailscale, never the public internet.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const PORT = Number(process.env.PI_RUNNER_PORT || 8091);
const HOME = process.env.HOME || "/var/lib/pi-runner";
// Invoke Pi's cli.js with the same node that runs this service, rather than the
// .bin/pi shebang (whose `#!/usr/bin/env node` can't resolve node under the
// hardened systemd PATH — "env: node: Permission denied").
const PI_CLI =
  process.env.PI_CLI ||
  join(HOME, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
const MODEL = process.env.PI_MODEL || "claude-sonnet-4-6";
const AUTH_FILE = join(HOME, ".pi", "agent", "auth.json");
const TIMEOUT_MS = Number(process.env.PI_TIMEOUT_MS || 300000); // 5 min

// ntfy token: systemd LoadCredential drops it at $CREDENTIALS_DIRECTORY/ntfy-token.
// We read it once and pass NTFY_TOKEN into the spawned Pi so the ntfy tool works.
let NTFY_TOKEN = process.env.NTFY_TOKEN || "";
try {
  const credDir = process.env.CREDENTIALS_DIRECTORY;
  if (!NTFY_TOKEN && credDir) {
    NTFY_TOKEN = readFileSync(join(credDir, "ntfy-token"), "utf8").trim();
  }
} catch {
  // token optional — the ntfy tool degrades gracefully if unset
}

// System prompt: the agent knows what box it's on and what it can touch.
const SYSTEM = `You are the homelab ops agent for "macbook-server", an always-on
NixOS home server (a 2011 MacBook Pro A1278). You answer operational questions
and perform light ops tasks. Local services you can reach over HTTP:
- AdGuard Home (DNS + ad-blocking) web API: http://localhost:80
- Home Assistant: http://localhost:8123
- ntfy (push notifications): http://127.0.0.1:8093  (topic "alerts")
- Glance dashboard: http://localhost:8080
- Server vitals/temps JSON: http://localhost:8090
Keep answers concise and factual. You run non-interactively; finish the task
and report the result in your final message.`;

function loggedIn() {
  try {
    if (!existsSync(AUTH_FILE)) return false;
    const j = JSON.parse(readFileSync(AUTH_FILE, "utf8"));
    return Boolean(j?.anthropic);
  } catch {
    return false;
  }
}

function runPi(ticket) {
  return new Promise((resolve) => {
    const args = [
      PI_CLI,
      "-p",
      "--mode", "json",
      "--provider", "anthropic",
      "--model", MODEL,
      "-np",
      "--append-system-prompt", SYSTEM,
      ticket,
    ];
    const child = spawn(process.execPath, args, {
      cwd: HOME,
      env: { ...process.env, HOME, NTFY_TOKEN },
      // Ignore stdin: under systemd there's no TTY, and Pi otherwise blocks
      // waiting to read piped stdin. (Manual TTY runs worked; the service hung.)
      stdio: ["ignore", "pipe", "pipe"],
    });

    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve({ ok: false, error: "timeout", answer: "" });
    }, TIMEOUT_MS);

    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));

    child.on("close", (code) => {
      clearTimeout(timer);
      // Parse JSONL; the final answer lives in the agent_end event's messages.
      let answer = "";
      for (const line of out.split("\n")) {
        const s = line.trim();
        if (!s) continue;
        let ev;
        try {
          ev = JSON.parse(s);
        } catch {
          continue;
        }
        if (ev.type === "agent_end" && Array.isArray(ev.messages)) {
          for (let i = ev.messages.length - 1; i >= 0; i--) {
            const m = ev.messages[i];
            if (m.role === "assistant" && Array.isArray(m.content)) {
              answer = m.content
                .filter((c) => c.type === "text")
                .map((c) => c.text)
                .join("")
                .trim();
              if (answer) break;
            }
          }
        }
      }
      if (answer) resolve({ ok: true, answer });
      else resolve({ ok: false, error: err.slice(-500) || `exit ${code}`, answer: "" });
    });
  });
}

const server = createServer((req, res) => {
  const send = (code, obj) => {
    const b = JSON.stringify(obj);
    res.writeHead(code, { "Content-Type": "application/json" });
    res.end(b);
  };

  if (req.method === "GET" && req.url === "/health") {
    return send(200, { ok: true, loggedIn: loggedIn() });
  }

  if (req.method === "POST" && req.url === "/run") {
    let body = "";
    req.on("data", (d) => {
      body += d;
      if (body.length > 100_000) req.destroy();
    });
    req.on("end", async () => {
      let ticket;
      try {
        ticket = JSON.parse(body).ticket;
      } catch {
        return send(400, { ok: false, error: "invalid JSON" });
      }
      if (!ticket || typeof ticket !== "string") {
        return send(400, { ok: false, error: "missing 'ticket'" });
      }
      if (!loggedIn()) {
        return send(503, {
          ok: false,
          error: "not logged in — run `pi /login anthropic` on the server",
        });
      }
      const t0 = Date.now();
      const r = await runPi(ticket);
      return send(r.ok ? 200 : 500, { ...r, ms: Date.now() - t0 });
    });
    return;
  }

  send(404, { ok: false, error: "not found" });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`pi-runner listening on 127.0.0.1:${PORT} (model ${MODEL})`);
});
