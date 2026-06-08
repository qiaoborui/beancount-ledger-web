"use client";

import { Search, X } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { useFocusTrap } from "./hooks/useFocusTrap";

export type CommandAction = {
  id: string;
  label: string;
  detail?: string;
  shortcut?: string;
  keywords?: string[];
  run: () => void;
};

export function CommandPalette({ open, actions, onOpenChange }: { open: boolean; actions: CommandAction[]; onOpenChange: (open: boolean) => void }) {
  const [query, setQuery] = useState("");
  const [activeIndex, setActiveIndex] = useState(0);
  const titleId = useId();
  const listboxId = useId();
  const panelRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const results = useMemo(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return actions;
    return actions.filter((action) => {
      const haystack = [action.label, action.detail, action.shortcut, ...(action.keywords ?? [])].filter(Boolean).join(" ").toLowerCase();
      return words.every((word) => haystack.includes(word));
    });
  }, [actions, query]);

  useEffect(() => {
    if (!open) return;
    setQuery("");
    setActiveIndex(0);
  }, [open]);

  useFocusTrap({ open, containerRef: panelRef, initialFocusRef: inputRef });

  useEffect(() => {
    if (!open) return;
    setActiveIndex((index) => Math.min(index, Math.max(0, results.length - 1)));
  }, [open, results.length]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        onOpenChange(true);
      }
      if (event.key === "Escape" && open) onOpenChange(false);
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onOpenChange, open]);

  if (!open) return null;

  const runAction = (action: CommandAction) => {
    action.run();
    onOpenChange(false);
  };
  const activeOptionId = results[activeIndex] ? `${listboxId}-option-${activeIndex}` : undefined;

  return (
    <div className="fixed inset-0 z-[130] flex items-start justify-center bg-ink/35 px-3 pt-[calc(env(safe-area-inset-top)+5rem)] backdrop-blur-sm" onMouseDown={() => onOpenChange(false)}>
      <div ref={panelRef} className="kami-float w-full max-w-2xl overflow-hidden rounded-2xl border border-line bg-paper shadow-xl" onMouseDown={(event) => event.stopPropagation()} role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1}>
        <h2 id={titleId} className="sr-only">命令面板</h2>
        <div className="flex items-center gap-3 border-b border-line px-4 py-3">
          <Search className="h-5 w-5 shrink-0 text-brand" />
          <input
            ref={inputRef}
            className="min-w-0 flex-1 border-0 bg-transparent px-0 py-1 text-base shadow-none outline-none focus:shadow-none"
            value={query}
            placeholder="搜索命令、页面或常用视图"
            role="combobox"
            aria-label="搜索命令"
            aria-autocomplete="list"
            aria-controls={listboxId}
            aria-expanded="true"
            aria-activedescendant={activeOptionId}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown") {
                event.preventDefault();
                setActiveIndex((index) => Math.min(results.length - 1, index + 1));
              }
              if (event.key === "ArrowUp") {
                event.preventDefault();
                setActiveIndex((index) => Math.max(0, index - 1));
              }
              if (event.key === "Enter" && results[activeIndex]) {
                event.preventDefault();
                runAction(results[activeIndex]);
              }
            }}
          />
          <button type="button" className="rounded-xl border border-line bg-panel p-2 text-stone hover:bg-tag" onClick={() => onOpenChange(false)} aria-label="关闭命令面板">
            <X className="h-4 w-4" />
          </button>
        </div>
        <div id={listboxId} className="max-h-[55dvh] overflow-y-auto p-2" role="listbox" aria-label="命令结果">
          {results.length ? results.map((action, index) => (
            <button
              key={action.id}
              id={`${listboxId}-option-${index}`}
              type="button"
              role="option"
              aria-selected={index === activeIndex}
              className={`flex w-full items-center justify-between gap-4 rounded-xl px-3 py-3 text-left ${index === activeIndex ? "bg-[var(--selected-bg)] text-ink" : "text-olive hover:bg-tag"}`}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => runAction(action)}
            >
              <span className="min-w-0">
                <span className="block truncate text-sm font-medium">{action.label}</span>
                {action.detail && <span className="mt-0.5 block truncate text-xs text-stone">{action.detail}</span>}
              </span>
              {action.shortcut && <kbd className="shrink-0 rounded-lg border border-line bg-panel px-2 py-1 text-[11px] text-stone">{action.shortcut}</kbd>}
            </button>
          )) : <div className="rounded-xl border border-line bg-panel p-5 text-center text-sm text-stone">没有匹配的命令</div>}
        </div>
      </div>
    </div>
  );
}
