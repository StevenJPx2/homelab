import { getSandbox } from "@cloudflare/sandbox";
import type { Env } from "./types";

const PI_CLI = "/opt/agent/node_modules/@earendil-works/pi-coding-agent/dist/cli.js";

/** Write the short-lived OAuth access token into the sandbox's Pi home. */
export async function injectAuth(env: Env, sandboxId: string, accessToken: string) {
  const sandbox = getSandbox(env.Sandbox, sandboxId);
  const auth = {
    anthropic: {
      type: "oauth",
      access: accessToken,
      refresh: "",
      // Pi only checks expiry locally; the token's real expiry is enforced
      // server-side. Runs are much shorter than the token lifetime.
      expires: Date.now() + 4 * 3600 * 1000,
    },
  };
  await sandbox.writeFile("/root/.pi/agent/auth.json", JSON.stringify(auth));
}

/** Clone the ticket's repo into /workspace/repo (idempotent). */
export async function cloneRepo(env: Env, sandboxId: string, repo: string) {
  const sandbox = getSandbox(env.Sandbox, sandboxId);
  const result = await sandbox.exec(
    `[ -d /workspace/repo/.git ] || git clone --depth 50 ${JSON.stringify(repo)} /workspace/repo`,
    { timeout: 180_000 },
  );
  if (result.exitCode !== 0) {
    throw new Error(`clone failed: ${result.stderr.slice(-500)}`);
  }
}

/**
 * Run the Pi agent headless inside the ticket's sandbox.
 * Stage gating (skeleton): read-only stages get a hard instruction prefix;
 * real per-stage tool gating comes with pi-workflow integration.
 */
export async function runAgent(
  env: Env,
  sandboxId: string,
  prompt: string,
  opts: { readOnly?: boolean; timeoutMs?: number } = {},
): Promise<string> {
  const sandbox = getSandbox(env.Sandbox, sandboxId);
  const guard = opts.readOnly
    ? "You are in READ-ONLY planning mode: do NOT create, modify or delete any files, do NOT run commands that change state (no installs, no git commits). Only read code and produce analysis.\n\n"
    : "";
  const fullPrompt = guard + prompt;
  // Write the prompt to a file to avoid shell-quoting pitfalls.
  await sandbox.writeFile("/workspace/.prompt", fullPrompt);
  const result = await sandbox.exec(
    `cd /workspace/repo && timeout 600 node ${PI_CLI} -p -np "$(cat /workspace/.prompt)" 2>&1 | tail -c 60000`,
    { timeout: opts.timeoutMs ?? 660_000 },
  );
  if (result.exitCode !== 0) {
    throw new Error(`agent run failed (exit ${result.exitCode}): ${result.stdout.slice(-800)}`);
  }
  return result.stdout.trim();
}
