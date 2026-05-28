"use client";

import type { AiToolEvent } from "@/lib/aiStream";
import { Tool, ToolContent, ToolHeader, ToolInput, ToolOutput } from "@/components/ai-elements/tool";

export type LedgerAiTool = AiToolEvent;

const toolState: Record<LedgerAiTool["status"], "input-streaming" | "input-available" | "output-available" | "output-error"> = {
  pending: "input-streaming",
  running: "input-available",
  completed: "output-available",
  error: "output-error",
};

export function upsertLedgerAiTool(tools: LedgerAiTool[], event: LedgerAiTool) {
  const index = tools.findIndex((tool) => tool.id === event.id);
  if (index < 0) return [...tools, event];
  return tools.map((tool, itemIndex) => (itemIndex === index ? { ...tool, ...event } : tool));
}

export function LedgerAiToolCard({ tools }: { tools: LedgerAiTool[] }) {
  if (tools.length === 0) return null;

  return (
    <div className="space-y-2">
      {tools.map((tool) => (
        <Tool key={tool.id} className="mb-0 rounded-2xl border-line bg-panel text-warm" defaultOpen={tool.status === "running" || tool.status === "error"}>
          <ToolHeader
            className="p-3"
            state={toolState[tool.status]}
            title={tool.title}
            toolName={tool.name}
            type="dynamic-tool"
          />
          <ToolContent className="space-y-3 px-3 pb-3 pt-0">
            {tool.input !== undefined && <ToolInput className="text-stone" input={tool.input} />}
            {(tool.output !== undefined || tool.error) && <ToolOutput className="text-stone" errorText={tool.error} output={tool.output} />}
          </ToolContent>
        </Tool>
      ))}
    </div>
  );
}
