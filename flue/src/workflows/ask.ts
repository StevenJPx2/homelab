import { defineWorkflow, type WorkflowRouteHandler } from '@flue/runtime';
import * as v from 'valibot';
import homelab from '../agents/homelab.ts';

// Simple bearer-token gate so the endpoint isn't open to the world.
// Set FLUE_API_TOKEN as a Worker secret; requests must send
//   Authorization: Bearer <token>
export const route: WorkflowRouteHandler = async (c, next) => {
  const expected = (c.env as Record<string, string | undefined>).FLUE_API_TOKEN;
  const got = c.req.header('authorization')?.replace(/^Bearer\s+/i, '');
  if (!expected || got !== expected) return c.text('unauthorized', 401);
  return next();
};

export default defineWorkflow({
  agent: homelab,
  input: v.object({ question: v.string() }),

  async run({ harness, input }) {
    const { data } = await (
      await harness.session()
    ).prompt(input.question, {
      result: v.object({
        answer: v.string(),
      }),
    });
    return data;
  },
});
