import { readJson } from "./clientFetch";

type AiStreamError = {
  error?: string;
};

export type AiToolEvent = {
  id: string;
  name: string;
  title: string;
  status: "pending" | "running" | "completed" | "error";
  input?: unknown;
  output?: unknown;
  error?: string;
};

export async function readAiEventStream<T>(
  response: Response,
  options: { onMessage: (text: string) => void; onStatus?: (text: string) => void; onTool?: (tool: AiToolEvent) => void }
): Promise<T> {
  if (!response.ok || !response.body) {
    const data = await readJson<AiStreamError>(response, {});
    throw new Error(data.error || "AI 流式请求失败");
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let final: T | null = null;

  while (true) {
    const { done, value } = await reader.read();
    if (value) {
      buffer += decoder.decode(value, { stream: !done });
      let separator = buffer.indexOf("\n\n");
      while (separator >= 0) {
        const chunk = buffer.slice(0, separator);
        buffer = buffer.slice(separator + 2);
        const event = parseSSEChunk(chunk);
        if (event) {
          if (event.type === "message") {
            const payload = JSON.parse(event.data) as { text?: string };
            if (typeof payload.text === "string") options.onMessage(payload.text);
          } else if (event.type === "status") {
            const payload = JSON.parse(event.data) as { text?: string };
            if (typeof payload.text === "string") options.onStatus?.(payload.text);
          } else if (event.type === "tool") {
            const payload = JSON.parse(event.data) as AiToolEvent;
            if (payload.id && payload.name && payload.title && payload.status) options.onTool?.(payload);
          } else if (event.type === "final") {
            final = JSON.parse(event.data) as T;
          } else if (event.type === "error") {
            const payload = JSON.parse(event.data) as AiStreamError;
            throw new Error(payload.error || "AI 流式请求失败");
          }
        }
        separator = buffer.indexOf("\n\n");
      }
    }
    if (done) break;
  }

  if (!final) {
    throw new Error("AI 流式响应未返回最终结果");
  }
  return final;
}

function parseSSEChunk(chunk: string): { type: string; data: string } | null {
  let type = "message";
  const data: string[] = [];
  for (const line of chunk.split(/\r?\n/)) {
    if (line.startsWith("event:")) type = line.slice(6).trim();
    if (line.startsWith("data:")) data.push(line.slice(5).trimStart());
  }
  if (!data.length) return null;
  return { type, data: data.join("\n") };
}
