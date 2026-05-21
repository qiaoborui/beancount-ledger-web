import { NextResponse } from "next/server";
import { z } from "zod";
import { apiHandler } from "@/lib/apiRoute";
import { requireAuthJson } from "@/lib/apiAuth";
import { chatBookkeeping } from "@/lib/deepseek";
import { logDuration } from "@/lib/diagnostics";
import { rateLimit } from "@/lib/rateLimit";
import { ParsedTransactionSchema } from "@/lib/schemas";

const ChatMessageSchema = z.object({
  role: z.enum(["user", "assistant"]),
  text: z.string(),
});

const ChatRequestSchema = z.object({
  message: z.string().min(1),
  messages: z.array(ChatMessageSchema).default([]),
  draftEntries: z.array(ParsedTransactionSchema).default([]),
  notifyOnLongTask: z.boolean().default(true),
});

export const POST = apiHandler(async (request: Request) => {
  const rateLimitError = rateLimit(request, { name: "ai.chat", limit: 20, windowMs: 5 * 60_000 });
  if (rateLimitError) return rateLimitError;

  const authError = await requireAuthJson();
  if (authError) return authError;
  const json = await request.json();
  const parsed = ChatRequestSchema.safeParse(json);
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid chat request" }, { status: 400 });
  }

  const today = new Date().toISOString().slice(0, 10);
  const startedAt = Date.now();
  const result = await chatBookkeeping({
    message: parsed.data.message,
    messages: parsed.data.messages,
    draftEntries: parsed.data.draftEntries,
    today,
  });
  const elapsedMs = Date.now() - startedAt;
  logDuration("ai.chat", startedAt, { entries: result.entries.length });
  return NextResponse.json({ ...result, meta: { elapsedMs } });
}, { defaultStatus: 400 });
