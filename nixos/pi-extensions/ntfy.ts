// Pi extension: gives the homelab agent a tool to send ntfy push notifications.
//
// The agent can call `send_notification` to push a message to the user's phone
// via the local ntfy service (ntfy.stevenjohn.co). Useful for ops tickets like
// "check disk usage and alert me if any filesystem is over 90%".
//
// Auth: reads the ntfy access token from $NTFY_TOKEN (supplied by the pi-runner
// systemd service from /var/lib/ntfy-token). Posts to the local ntfy instance on
// 127.0.0.1:8093 so nothing leaves the box unencrypted.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const NTFY_URL = process.env.NTFY_URL || "http://127.0.0.1:8093";
const DEFAULT_TOPIC = process.env.NTFY_TOPIC || "alerts";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "send_notification",
    label: "Send ntfy notification",
    description:
      "Send a push notification to the user's phone via ntfy. Use this to " +
      "alert the user about homelab status, task results, or anything worth " +
      "their attention. Keep the title short and the body concise.",
    parameters: Type.Object({
      title: Type.String({ description: "Short notification title" }),
      message: Type.String({ description: "Notification body text" }),
      priority: Type.Optional(
        Type.Union(
          [
            Type.Literal("min"),
            Type.Literal("low"),
            Type.Literal("default"),
            Type.Literal("high"),
            Type.Literal("urgent"),
          ],
          { description: "Notification priority (default: default)" },
        ),
      ),
      tags: Type.Optional(
        Type.String({
          description:
            "Comma-separated ntfy tags/emojis, e.g. 'warning,cpu' or 'white_check_mark'",
        }),
      ),
      topic: Type.Optional(
        Type.String({ description: `ntfy topic (default: ${DEFAULT_TOPIC})` }),
      ),
    }),
    async execute(_toolCallId, params) {
      const token = process.env.NTFY_TOKEN;
      if (!token) {
        return {
          content: [
            { type: "text", text: "ntfy not configured: NTFY_TOKEN is unset." },
          ],
          details: {},
        };
      }
      const topic = params.topic || DEFAULT_TOPIC;
      const headers: Record<string, string> = {
        Authorization: `Bearer ${token}`,
        Title: params.title,
      };
      if (params.priority) headers["Priority"] = params.priority;
      if (params.tags) headers["Tags"] = params.tags;

      try {
        const res = await fetch(`${NTFY_URL}/${topic}`, {
          method: "POST",
          headers,
          body: params.message,
        });
        if (!res.ok) {
          const body = await res.text();
          return {
            content: [
              {
                type: "text",
                text: `ntfy send failed: HTTP ${res.status} ${body.slice(0, 200)}`,
              },
            ],
            details: {},
          };
        }
        return {
          content: [
            {
              type: "text",
              text: `Notification sent to '${topic}': ${params.title}`,
            },
          ],
          details: {},
        };
      } catch (e) {
        return {
          content: [
            { type: "text", text: `ntfy send error: ${(e as Error).message}` },
          ],
          details: {},
        };
      }
    },
  });
}
