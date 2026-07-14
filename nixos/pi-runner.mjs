// pi-runner — headless Pi agent box for homelab ops, with a SQLite job queue,
// history, and a small web UI.
//
//   GET  /              -> HTML UI (file a ticket, watch past runs)
//   POST /run           -> {ticket} ; runs to completion, returns the record
//                          (add ?async=1 to return immediately with the id)
//   GET  /tickets       -> recent ticket records (JSON)
//   GET  /tickets/:id   -> one ticket record
//   GET  /health        -> {ok, loggedIn, queued, running}
//
// Tickets run SERIALLY (one at a time) so parallel agents never pile up on the
// old i5 — the whole point of keeping heavy work off this box.
//
// Auth: Claude Pro/Max OAuth token in $HOME/.pi/agent/auth.json (+ the
// @gotgenes/pi-anthropic-auth extension). No API key. Bound to 127.0.0.1 —
// reachable only via localhost / Tailscale.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

const PORT = Number(process.env.PI_RUNNER_PORT || 8091);
const HOST = process.env.PI_RUNNER_HOST || "0.0.0.0"; // firewalled to LAN/Tailscale
const HOME = process.env.HOME || "/var/lib/pi-runner";
const PI_CLI =
  process.env.PI_CLI ||
  join(HOME, "node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
const MODEL = process.env.PI_MODEL || "claude-sonnet-4-6";
const AUTH_FILE = join(HOME, ".pi", "agent", "auth.json");
const TIMEOUT_MS = Number(process.env.PI_TIMEOUT_MS || 300000); // 5 min
const DB_PATH = process.env.PI_DB || join(HOME, "tickets.db");

// ntfy token: systemd LoadCredential drops it at $CREDENTIALS_DIRECTORY/ntfy-token.
let NTFY_TOKEN = process.env.NTFY_TOKEN || "";
try {
  const credDir = process.env.CREDENTIALS_DIRECTORY;
  if (!NTFY_TOKEN && credDir) {
    NTFY_TOKEN = readFileSync(join(credDir, "ntfy-token"), "utf8").trim();
  }
} catch {
  /* token optional */
}

const SYSTEM = `You are the homelab ops agent for "macbook-server", an always-on
NixOS home server (a 2011 MacBook Pro A1278). You answer operational questions
and perform light ops tasks. Local services you can reach over HTTP:
- AdGuard Home (DNS + ad-blocking) web API: http://localhost:80
- Home Assistant: http://localhost:8123
- ntfy (push notifications): http://127.0.0.1:8093  (topic "alerts")
- Glance dashboard: http://localhost:8080
- Server vitals/temps JSON: http://localhost:8090
You also have a send_notification tool to push messages to the user's phone.
Keep answers concise and factual. You run non-interactively; finish the task
and report the result in your final message.`;

// --- Database ---
const db = new DatabaseSync(DB_PATH);
db.exec(`
  CREATE TABLE IF NOT EXISTS tickets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    prompt TEXT NOT NULL,
    status TEXT NOT NULL,            -- queued | running | done | error
    answer TEXT,
    error TEXT,
    created_at INTEGER NOT NULL,
    finished_at INTEGER,
    ms INTEGER
  );
`);
const q = {
  insert: db.prepare(
    "INSERT INTO tickets (prompt, status, created_at) VALUES (?, 'queued', ?)",
  ),
  setRunning: db.prepare("UPDATE tickets SET status='running' WHERE id=?"),
  finishOk: db.prepare(
    "UPDATE tickets SET status='done', answer=?, finished_at=?, ms=? WHERE id=?",
  ),
  finishErr: db.prepare(
    "UPDATE tickets SET status='error', error=?, finished_at=?, ms=? WHERE id=?",
  ),
  byId: db.prepare("SELECT * FROM tickets WHERE id=?"),
  recent: db.prepare("SELECT * FROM tickets ORDER BY id DESC LIMIT 50"),
  activeCount: db.prepare(
    "SELECT COUNT(*) n FROM tickets WHERE status IN ('queued','running')",
  ),
};
// On boot, any ticket left 'running'/'queued' from a crash is marked error.
db.exec(
  "UPDATE tickets SET status='error', error='interrupted by restart' WHERE status IN ('queued','running')",
);

function loggedIn() {
  try {
    if (!existsSync(AUTH_FILE)) return false;
    return Boolean(JSON.parse(readFileSync(AUTH_FILE, "utf8"))?.anthropic);
  } catch {
    return false;
  }
}

// --- Serial job queue ---
const queue = [];
let running = false;

function enqueue(id, prompt) {
  queue.push({ id, prompt });
  pump();
}

async function pump() {
  if (running) return;
  const job = queue.shift();
  if (!job) return;
  running = true;
  q.setRunning.run(job.id);
  const t0 = Date.now();
  const r = await runPi(job.prompt);
  const ms = Date.now() - t0;
  if (r.ok) q.finishOk.run(r.answer, Date.now(), ms, job.id);
  else q.finishErr.run(r.error || "unknown error", Date.now(), ms, job.id);
  running = false;
  pump(); // next
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
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      resolve({ ok: false, error: "timeout" });
    }, TIMEOUT_MS);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      clearTimeout(timer);
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
      else resolve({ ok: false, error: err.slice(-500) || `exit ${code}` });
    });
  });
}

// --- HTTP ---
function send(res, code, obj) {
  const b = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(b);
}

function waitFor(id) {
  // Resolve when the ticket reaches a terminal state.
  return new Promise((resolve) => {
    const check = () => {
      const row = q.byId.get(id);
      if (row && (row.status === "done" || row.status === "error")) resolve(row);
      else setTimeout(check, 400);
    };
    check();
  });
}

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const path = url.pathname;

  if (req.method === "GET" && path === "/health") {
    const n = q.activeCount.get().n;
    return send(res, 200, {
      ok: true,
      loggedIn: loggedIn(),
      running,
      queued: Math.max(0, n - (running ? 1 : 0)),
    });
  }

  if (req.method === "GET" && path === "/") {
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(HTML);
  }

  if (req.method === "GET" && path === "/tickets") {
    return send(res, 200, { tickets: q.recent.all() });
  }

  const m = path.match(/^\/tickets\/(\d+)$/);
  if (req.method === "GET" && m) {
    const row = q.byId.get(Number(m[1]));
    return row ? send(res, 200, row) : send(res, 404, { error: "not found" });
  }

  if (req.method === "POST" && path === "/run") {
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
        return send(res, 400, { ok: false, error: "invalid JSON" });
      }
      if (!ticket || typeof ticket !== "string")
        return send(res, 400, { ok: false, error: "missing 'ticket'" });
      if (!loggedIn())
        return send(res, 503, {
          ok: false,
          error: "not logged in — run `pi /login anthropic` on the server",
        });
      const info = q.insert.run(ticket, Date.now());
      const id = Number(info.lastInsertRowid);
      enqueue(id, ticket);
      if (url.searchParams.get("async") === "1") {
        return send(res, 202, { ok: true, id, status: "queued" });
      }
      const row = await waitFor(id);
      return send(res, row.status === "done" ? 200 : 500, {
        ok: row.status === "done",
        id,
        answer: row.answer || "",
        error: row.error || undefined,
        ms: row.ms,
      });
    });
    return;
  }

  send(res, 404, { ok: false, error: "not found" });
});

server.listen(PORT, HOST, () => {
  console.log(`pi-runner listening on ${HOST}:${PORT} (model ${MODEL})`);
});

// --- UI (single self-contained page; talks to the JSON endpoints above) ---
const HTML = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agent Tickets · macbook-server</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.5 system-ui,sans-serif; background:#1a1b26; color:#c0caf5; }
  header { padding:1rem 1.25rem; border-bottom:1px solid #292e42; display:flex; align-items:center; gap:.75rem; }
  header h1 { font-size:1.05rem; margin:0; font-weight:600; }
  #status { font-size:.8rem; color:#7aa2f7; margin-left:auto; }
  main { max-width:780px; margin:0 auto; padding:1.25rem; }
  form { display:flex; flex-direction:column; gap:.6rem; margin-bottom:1.5rem; }
  textarea { width:100%; min-height:80px; resize:vertical; background:#24283b; color:#c0caf5;
    border:1px solid #414868; border-radius:8px; padding:.7rem; font:inherit; }
  button { align-self:flex-end; background:#7aa2f7; color:#1a1b26; border:0; border-radius:8px;
    padding:.55rem 1.1rem; font-weight:600; cursor:pointer; }
  button:disabled { opacity:.5; cursor:default; }
  .ticket { background:#24283b; border:1px solid #292e42; border-radius:10px; padding:.8rem 1rem; margin-bottom:.7rem; }
  .ticket .top { display:flex; align-items:center; gap:.6rem; font-size:.82rem; color:#7f88b3; }
  .ticket .prompt { margin:.35rem 0; font-weight:500; color:#c0caf5; white-space:pre-wrap; }
  .ticket .answer { white-space:pre-wrap; color:#9ece6a; margin-top:.4rem; font-size:.92rem; }
  .ticket .answer.err { color:#f7768e; }
  .badge { padding:.05rem .5rem; border-radius:99px; font-size:.72rem; font-weight:600; }
  .queued { background:#414868; color:#c0caf5; }
  .running { background:#e0af68; color:#1a1b26; }
  .done { background:#9ece6a; color:#1a1b26; }
  .error { background:#f7768e; color:#1a1b26; }
  .muted { color:#565f89; }
</style></head>
<body>
<header><h1>🐴 Agent Tickets</h1><span id="status">…</span></header>
<main>
  <form id="f">
    <textarea id="t" placeholder="File a ticket — e.g. 'Check AdGuard: how many DNS queries were blocked in the last 24h?'" required></textarea>
    <button id="b" type="submit">Run ticket</button>
  </form>
  <div id="list"></div>
</main>
<script>
const fmt = (ts) => ts ? new Date(ts).toLocaleString() : "";
async function refresh() {
  try {
    const h = await (await fetch("/health")).json();
    document.getElementById("status").textContent =
      (h.loggedIn ? "● online" : "● not logged in") +
      (h.running ? " · running" : "") + (h.queued ? " · " + h.queued + " queued" : "");
    const { tickets } = await (await fetch("/tickets")).json();
    document.getElementById("list").innerHTML = tickets.map(t => \`
      <div class="ticket">
        <div class="top">
          <span class="badge \${t.status}">\${t.status}</span>
          <span>#\${t.id}</span>
          <span class="muted">\${fmt(t.created_at)}\${t.ms ? " · " + (t.ms/1000).toFixed(1) + "s" : ""}</span>
        </div>
        <div class="prompt">\${esc(t.prompt)}</div>
        \${t.answer ? '<div class="answer">'+esc(t.answer)+'</div>' : ''}
        \${t.error ? '<div class="answer err">'+esc(t.error)+'</div>' : ''}
      </div>\`).join("") || '<p class="muted">No tickets yet.</p>';
  } catch (e) { document.getElementById("status").textContent = "● offline"; }
}
function esc(s){return (s||"").replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));}
document.getElementById("f").addEventListener("submit", async (e) => {
  e.preventDefault();
  const t = document.getElementById("t"), b = document.getElementById("b");
  if (!t.value.trim()) return;
  b.disabled = true; b.textContent = "Queued…";
  await fetch("/run?async=1", { method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({ ticket: t.value.trim() }) });
  t.value = ""; b.disabled = false; b.textContent = "Run ticket";
  refresh();
});
refresh();
setInterval(refresh, 2500);
</script>
</body></html>`;
