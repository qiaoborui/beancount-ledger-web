import { apiFetch } from "./apiEndpoints";
import { readJson } from "./clientFetch";

/** A generated title has to fit the sidebar row and the mobile header. */
export const AGENT_SESSION_TITLE_MAX_LENGTH = 28;

type AgentSessionTitleResponse = { title?: unknown };

/**
 * Reduce a model reply to one short label. Models occasionally answer with a
 * bolded label, a quoted phrase, a trailing sentence on the same line, or an
 * explanation after a newline; a session title only ever needs the first line.
 */
export function sanitizeAgentSessionTitle(value: unknown): string {
  if (typeof value !== "string") return "";
  const firstLine = value.split(/\r?\n/).map((line) => line.trim()).find((line) => line.length > 0) ?? "";
  let title = firstLine;
  for (;;) {
    const before = title;
    title = title.trim()
      .replace(/^[*`"'「」『』《》]+/u, "")
      .replace(/[*`"'「」『』《》]+$/u, "")
      .replace(/^(?:会话标题|标题|title)\s*[:：]\s*/iu, "")
      .trim()
      .replace(/[。.!！?？,，、；;：:]+$/u, "")
      .trim();
    if (title === before) break;
  }
  if (!title) return "";
  const characters = Array.from(title);
  if (characters.length <= AGENT_SESSION_TITLE_MAX_LENGTH) return title;
  return characters.slice(0, AGENT_SESSION_TITLE_MAX_LENGTH).join("").trim();
}

/**
 * Ask the server for a title for the conversation that just opened. Title
 * generation is decoration: an unavailable model, an offline server, or a
 * useless reply all fall back to the first question, so this never throws.
 */
export async function requestAgentSessionTitle(question: string, answer: string): Promise<string> {
  const trimmedQuestion = question.trim();
  if (!trimmedQuestion) return "";
  try {
    const response = await apiFetch("/api/ai/agent/session-title", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question: trimmedQuestion, answer: answer.trim() }),
    });
    if (!response.ok) return "";
    const data = await readJson<AgentSessionTitleResponse>(response, {});
    return sanitizeAgentSessionTitle(data.title);
  } catch {
    return "";
  }
}
