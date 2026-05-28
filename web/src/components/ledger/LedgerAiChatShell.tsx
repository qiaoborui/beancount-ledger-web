"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Bot, Trash2, X } from "lucide-react";
import {
  Conversation,
  ConversationContent,
  ConversationScrollButton,
} from "@/components/ai-elements/conversation";
import {
  Message,
  MessageContent,
  MessageResponse,
} from "@/components/ai-elements/message";
import {
  PromptInput,
  PromptInputBody,
  PromptInputFooter,
  PromptInputSubmit,
  PromptInputTextarea,
} from "@/components/ai-elements/prompt-input";
import { Suggestion, Suggestions } from "@/components/ai-elements/suggestion";

export type LedgerAiChatMessage = {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
};

type LedgerAiChatShellProps = {
  open: boolean;
  title: string;
  statusText: string;
  messages: LedgerAiChatMessage[];
  input: string;
  placeholder: string;
  note: string;
  busy: boolean;
  inputDisabled?: boolean;
  thinkingText?: string;
  suggestions?: string[];
  widthClassName?: string;
  onInputChange: (value: string) => void;
  onSubmit: (text: string) => void | Promise<void>;
  onReset: () => void;
  onClose: () => void;
  children?: ReactNode;
};

export function LedgerAiChatShell({
  open,
  title,
  statusText,
  messages,
  input,
  placeholder,
  note,
  busy,
  inputDisabled = false,
  thinkingText,
  suggestions = [],
  widthClassName = "md:w-[420px]",
  onInputChange,
  onSubmit,
  onReset,
  onClose,
  children,
}: LedgerAiChatShellProps) {
  const [keyboardHeight, setKeyboardHeight] = useState(0);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    if (!open) {
      setKeyboardHeight(0);
      return;
    }
    textareaRef.current?.focus();
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      const kbH = Math.max(0, window.innerHeight - vv.height - (vv.offsetTop || 0));
      setKeyboardHeight(kbH > 50 ? kbH : 0);
    };
    vv.addEventListener("resize", update);
    vv.addEventListener("scroll", update);
    update();
    return () => {
      vv.removeEventListener("resize", update);
      vv.removeEventListener("scroll", update);
    };
  }, [open]);

  if (!open) return null;

  async function handleSubmit(message: { text: string }) {
    const text = message.text.trim();
    if (!text || busy) return;
    await onSubmit(text);
    onInputChange("");
  }

  function handleSuggestion(suggestion: string) {
    if (busy || inputDisabled) return;
    onInputChange(suggestion);
    requestAnimationFrame(() => textareaRef.current?.focus());
  }

  const shell = (
    <div
      className={`kami-float fixed inset-x-0 top-0 bottom-[var(--ledger-ai-chat-bottom)] z-50 flex w-full flex-col overflow-hidden bg-paper md:inset-x-auto md:right-6 md:top-auto md:bottom-[calc(7rem+env(safe-area-inset-bottom))] md:h-[min(78dvh,680px)] ${widthClassName} md:max-w-md md:rounded-3xl md:border md:border-line`}
      style={{ "--ledger-ai-chat-bottom": `${keyboardHeight}px` } as CSSProperties}
    >
      <div className="flex shrink-0 items-center justify-between border-b border-line bg-panel px-4 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] md:py-3">
        <div className="flex min-w-0 items-center gap-2">
          <div className="grid h-9 w-9 shrink-0 place-items-center rounded-2xl bg-brand text-paper"><Bot className="h-4 w-4" /></div>
          <div className="min-w-0">
            <div className="truncate font-serif text-lg text-warm">{title}</div>
            <div className="truncate text-xs text-stone">{statusText}</div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <button type="button" className="rounded-xl border border-line p-2 text-stone hover:text-[var(--danger)] disabled:opacity-50" onClick={onReset} disabled={busy} aria-label={`清空${title}对话`} title="清空对话">
            <Trash2 className="h-4 w-4" />
          </button>
          <button type="button" className="rounded-xl border border-line p-2 text-stone hover:text-warm" onClick={onClose} aria-label={`关闭${title}`}>
            <X className="h-4 w-4" />
          </button>
        </div>
      </div>

      <Conversation className="min-h-0 flex-1">
        <ConversationContent className="gap-3 p-4">
          {messages.map((message) => {
            const from = message.role === "user" ? "user" : "assistant";
            if (from === "assistant" && !message.text.trim()) return null;
            return (
              <Message key={message.id} from={from} className="max-w-[88%]">
                <MessageContent className={from === "user" ? "rounded-2xl bg-brand px-3 py-2 text-paper" : "rounded-2xl border border-line bg-panel px-3 py-2 text-warm"}>
                  {from === "user" ? (
                    <div className="whitespace-pre-wrap leading-relaxed">{message.text}</div>
                  ) : (
                    <MessageResponse className="whitespace-pre-wrap text-sm leading-relaxed text-warm">{message.text}</MessageResponse>
                  )}
                </MessageContent>
              </Message>
            );
          })}
          {busy && thinkingText && <div className="text-sm text-stone">{thinkingText}</div>}
          {children}
        </ConversationContent>
        <ConversationScrollButton className="border-line bg-paper text-brand hover:bg-tag" />
      </Conversation>

      <div className="shrink-0 border-t border-line bg-paper px-4 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-3 md:p-3">
        {suggestions.length > 0 && (
          <Suggestions className="pb-2">
            {suggestions.map((suggestion) => (
              <Suggestion
                key={suggestion}
                className="border-line bg-paper text-stone hover:bg-tag hover:text-warm"
                disabled={busy || inputDisabled}
                suggestion={suggestion}
                onClick={handleSuggestion}
              />
            ))}
          </Suggestions>
        )}
        <PromptInput className="rounded-2xl border border-line bg-panel" onSubmit={handleSubmit}>
          <PromptInputBody>
            <PromptInputTextarea
              ref={textareaRef}
              className="max-h-48 min-h-24 bg-transparent p-3 text-sm leading-relaxed outline-none"
              disabled={inputDisabled}
              placeholder={placeholder}
              value={input}
              onChange={(event) => onInputChange(event.currentTarget.value)}
            />
          </PromptInputBody>
          <PromptInputFooter className="border-t border-line px-3 py-2">
            <div className="min-w-0 text-xs text-stone">{note}</div>
            <PromptInputSubmit className="shrink-0 bg-brand text-paper hover:bg-brandLight" disabled={!input.trim() || busy} status={busy ? "submitted" : undefined} />
          </PromptInputFooter>
        </PromptInput>
      </div>
    </div>
  );

  return createPortal(shell, document.body);
}
