import { MessageResponse } from "@/components/ai-elements/message";

export function AgentMessageBubble({ role, content }: { role: "user" | "assistant"; content: string }) {
  const user = role === "user";
  return <div className={`flex min-w-0 max-w-full ${user ? "justify-end" : "justify-start"}`}>
    <div className={`min-w-0 max-w-[92%] break-words rounded-md px-3 py-2 text-sm leading-relaxed [overflow-wrap:anywhere] ${user ? "whitespace-pre-wrap bg-brand text-paper" : "border border-line bg-panel text-ink [&_a]:break-all [&_code]:break-words [&_pre]:max-w-full [&_pre]:overflow-x-auto [&_pre]:rounded-sm [&_pre]:bg-paper [&_pre]:p-2"}`}>
      {user ? content : <MessageResponse>{content}</MessageResponse>}
    </div>
  </div>;
}
