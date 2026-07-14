import { getSandbox } from "@cloudflare/sandbox";

export { Sandbox } from "@cloudflare/sandbox";

interface Env {
  Sandbox: DurableObjectNamespace<import("@cloudflare/sandbox").Sandbox>;
  SPIKE_TOKEN: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Simple bearer auth — this worker can execute arbitrary commands.
    const auth = request.headers.get("authorization") ?? "";
    if (auth !== `Bearer ${env.SPIKE_TOKEN}`) {
      return new Response("unauthorized", { status: 401 });
    }

    const sandbox = getSandbox(env.Sandbox, "phase0");

    // Phase 0 proof #1: environment sanity — what's in the container?
    if (url.pathname === "/env") {
      const result = await sandbox.exec(
        "echo node=$(node --version 2>/dev/null); echo git=$(git --version 2>/dev/null); echo python=$(python3 --version 2>/dev/null); uname -a"
      );
      return Response.json({
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      });
    }

    // Phase 0 proof #2: clone a real repo and inspect it (the heavy-tool primitive)
    if (url.pathname === "/clone") {
      const repo = url.searchParams.get("repo") ?? "https://github.com/cortexkit/aft";
      const result = await sandbox.exec(
        `rm -rf /workspace/repo && git clone --depth 1 ${JSON.stringify(repo)} /workspace/repo 2>&1 | tail -2 && echo "---" && ls /workspace/repo | head -20`,
        { timeout: 120_000 }
      );
      return Response.json({
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      });
    }

    // Phase 0 proof #3: run an arbitrary command (build/test primitive)
    if (url.pathname === "/exec" && request.method === "POST") {
      const { cmd } = (await request.json()) as { cmd: string };
      const result = await sandbox.exec(cmd, { timeout: 300_000 });
      return Response.json({
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      });
    }

    return new Response("workhorse phase-0 spike: /env, /clone?repo=..., POST /exec {cmd}");
  },
};
