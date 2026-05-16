import { NextResponse } from "next/server";
import { z } from "zod";
import { requireAuthJson } from "@/lib/apiAuth";
import { chatBookkeeping } from "@/lib/deepseek";
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

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;
  const json = await request.json();
  const parsed = ChatRequestSchema.safeParse(json);
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid chat request" }, { status: 400 });
  }

  const today = new Date().toISOString().slice(0, 10);
  const startedAt = Date.now();
  try {
    const result = await chatBookkeeping({
      message: parsed.data.message,
      messages: parsed.data.messages,
      draftEntries: parsed.data.draftEntries,
      today,
    });
    const elapsedMs = Date.now() - startedAt;
    return NextResponse.json({ ...result, meta: { elapsedMs } });
  } catch (error) {
    const elapsedMs = Date.now() - startedAt;
    const message = error instanceof Error ? error.message : String(error);
    return NextResponse.json({ error: message, meta: { elapsedMs } }, { status: 400 });
  }
}
