"use client";

import { createPortal } from "react-dom";
import { useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import { Archive, ArchiveRestore, Ban, Bot, Check, ChevronDown, ChevronUp, ClipboardPenLine, ExternalLink, History, LineChart as LineChartIcon, ListChecks, LoaderCircle, LockKeyhole, Maximize2, Minimize2, MoreHorizontal, Play, Plus, Send, SlidersHorizontal, Sparkles, Trash2, Wrench, X } from "lucide-react";
import { Bar, BarChart, CartesianGrid, Cell, Line, LineChart, Pie, PieChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { apiEndpointLedgerScope, apiFetch, apiSensitiveDataLockedEvent } from "@/lib/apiEndpoints";
import i18n from "@/i18n";
import { readLedgerAgentStream, type AgentArtifact, type AgentFinal, type AgentToolEvent } from "@/lib/ledgerAgentStream";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { MessageResponse } from "@/components/ai-elements/message";
import type { ParsedTransaction } from "@/lib/schemas";
import { AgentMessageBubble } from "./AgentMessageBubble";
import { useDesktopViewport } from "./hooks/useDesktopViewport";
import {
  readStoredAgent,
  readStoredAgentMetadata,
  restoreTimeline,
  timelineTitle,
  writeStoredAgent,
  type AgentSession,
  type MessageItem,
  type TimelineItem,
  type ToolItem,
} from "./ledgerAgentStorage";
import type { AccountOperation } from "./types";

type AgentContext = {
  page: string;
  path: string;
  start: string;
  end: string;
  valuationCurrency: string;
  bqlQuery?: string;
};

export type LedgerAgentRequest = {
  id: number;
  prompt?: string;
  autoSubmit?: boolean;
};

const AGENT_TIMELINE_PAGE_SIZE = 80;
const AGENT_TIMELINE_REFRESH_MS = 1500;
type AgentTimelinePage = { items: TimelineItem[]; nextBefore: number | null };
type TimelinePagination = { loading: boolean; nextBefore: number | null };

type BQLColumn = { name: string; type: string };
type BQLResult = { columns: BQLColumn[]; rows: unknown[][]; query: string; warnings?: string[]; valuationCurrency: string; rowCount: number };

type AgentStarter = { labelKey: string; descriptionKey: string; promptKey: string; icon: ReactNode };

const agentStarters: AgentStarter[] = [
  { labelKey: "agentWorkspace.starterExpenseAnalysis", descriptionKey: "agentWorkspace.starterExpenseAnalysisDesc", promptKey: "agentWorkspace.starterExpenseAnalysisPrompt", icon: <LineChartIcon className="h-4 w-4" /> },
  { labelKey: "agentWorkspace.starterDraft", descriptionKey: "agentWorkspace.starterDraftDesc", promptKey: "agentWorkspace.starterDraftPrompt", icon: <ClipboardPenLine className="h-4 w-4" /> },
  { labelKey: "agentWorkspace.starterReconcile", descriptionKey: "agentWorkspace.starterReconcileDesc", promptKey: "agentWorkspace.starterReconcilePrompt", icon: <ListChecks className="h-4 w-4" /> },
  { labelKey: "agentWorkspace.starterAccounts", descriptionKey: "agentWorkspace.starterAccountsDesc", promptKey: "agentWorkspace.starterAccountsPrompt", icon: <Wrench className="h-4 w-4" /> },
  { labelKey: "agentWorkspace.starterImports", descriptionKey: "agentWorkspace.starterImportsDesc", promptKey: "agentWorkspace.starterImportsPrompt", icon: <Sparkles className="h-4 w-4" /> },
];

const suggestions = agentStarters.slice(0, 4).map((starter) => i18n.t(starter.promptKey));

const chartColors = ["var(--chart-palette-1, var(--chart-primary))", "var(--chart-palette-2, var(--stone))", "var(--chart-palette-3, var(--brand))", "var(--chart-palette-4, var(--warm))"];

function nextID() {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

function containsSensitiveAgentInput(value: string) {
  return /密码|口令|验证码|密钥|身份证|\b(password|passcode|pin|otp|token|secret|cvv)\b/i.test(value) || /(?:\d[ -]?){12,}/.test(value);
}

export function agentToolNeedsSensitiveUnlock(error: string | undefined) {
  return Boolean(error && (/请先解锁敏感数据/.test(error) || /Sensitive data is locked/i.test(error)));
}

function requestAgentSensitiveUnlock() {
  window.dispatchEvent(new Event(apiSensitiveDataLockedEvent));
}

function createAgentSession(timeline: TimelineItem[] = [], serverSessionId = `session-${nextID()}`): AgentSession {
  const now = Date.now();
  return { id: nextID(), serverSessionId, title: timelineTitle(timeline), archived: false, createdAt: now, updatedAt: now, timelineState: "available", timeline };
}

function sessionLabel(session: AgentSession) {
  return session.title || timelineTitle(session.timeline) || i18n.t("agentWorkspace.newChat");
}

export function activeTurnTools(timeline: TimelineItem[]) {
  const lastUserIndex = timeline.findLastIndex((item) => item.kind === "message" && item.role === "user");
  if (lastUserIndex < 0) return [];
  return timeline.slice(lastUserIndex + 1).filter((item): item is ToolItem => item.kind === "tool");
}

function sessionTime(session: AgentSession) {
  return new Intl.DateTimeFormat(i18n.language, { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(session.updatedAt);
}

export function LedgerAgentWorkspace({
  presentation = "dock",
  request,
  open: controlledOpen,
  onOpenChange,
  context,
  onApplyBQL,
  onNavigate,
  onChanged,
  showToast,
}: {
  presentation?: "dock" | "page";
  request?: LedgerAgentRequest | null;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  context: AgentContext;
  onApplyBQL: (query: string) => void;
  onNavigate: (path: string) => void;
  onChanged: () => void | Promise<void>;
  showToast: (kind: "info" | "success" | "error", text: string) => void;
}) {
  const ledgerScope = useMemo(() => apiEndpointLedgerScope(), []);
  const metadata = useMemo(() => readStoredAgentMetadata(ledgerScope), [ledgerScope]);
  const stored = useMemo(() => {
    if (metadata?.sessions.length) return metadata;
    const session = createAgentSession();
    return { activeSessionId: session.id, sessions: [session], deletedServerSessionIds: [] };
  }, [metadata]);
  const [uncontrolledOpen, setUncontrolledOpen] = useState(false);
  const [sessions, setSessions] = useState<AgentSession[]>(stored.sessions);
  const [activeSessionId, setActiveSessionId] = useState(stored.activeSessionId);
  const [deletedServerSessionIds, setDeletedServerSessionIds] = useState(stored.deletedServerSessionIds);
  const [localHydrationReady, setLocalHydrationReady] = useState(false);
  const [showArchivedSessions, setShowArchivedSessions] = useState(false);
  const [sessionMutationID, setSessionMutationID] = useState("");
  const [timelinePagination, setTimelinePagination] = useState<Record<string, TimelinePagination>>({});
  const [desktopFullscreen, setDesktopFullscreen] = useState(false);
  const [mobileSessionListOpen, setMobileSessionListOpen] = useState(false);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState(i18n.t("agentWorkspace.ready"));
  const [streamingText, setStreamingText] = useState("");
  const [expandedTools, setExpandedTools] = useState<Record<string, boolean>>({});
  const desktopViewport = useDesktopViewport();
  const requestRef = useRef(0);
  const streamingMessageIDRef = useRef("");
  const sendRef = useRef<(text: string) => Promise<void>>(async () => undefined);
  const desktopScrollRef = useRef<HTMLDivElement | null>(null);
  const fullscreenScrollRef = useRef<HTMLDivElement | null>(null);
  const mobileScrollRef = useRef<HTMLDivElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const open = controlledOpen ?? uncontrolledOpen;
  const activeSession = sessions.find((session) => session.id === activeSessionId) ?? sessions[0];
  const sessionId = activeSession.serverSessionId || `session-${activeSession.id}`;
  const timeline = activeSession.timeline;
  const archivedSessionCount = sessions.filter((session) => session.archived).length;
  const sidebarSessions = sessions.filter((session) => !session.archived || showArchivedSessions);
  const liveTools = busy ? activeTurnTools(timeline) : [];
  const liveToolIDs = new Set(liveTools.map((item) => item.id));

  function setOpen(next: boolean) {
    setUncontrolledOpen(next);
    onOpenChange?.(next);
  }

  function updateActiveSession(update: (session: AgentSession) => AgentSession) {
    setSessions((current) => current.map((session) => session.id === activeSession.id ? update(session) : session));
  }

  function updateTimeline(update: (timeline: TimelineItem[]) => TimelineItem[]) {
    updateActiveSession((session) => {
      const timeline = update(session.timeline);
      return { ...session, title: session.title || timelineTitle(timeline), timelineState: "available", timeline, updatedAt: Date.now() };
    });
  }

  function createSession() {
    if (busy || !localHydrationReady) return;
    const session = createAgentSession();
    setSessions((current) => [session, ...current]);
    setActiveSessionId(session.id);
    setMobileSessionListOpen(false);
    setInput("");
    setStreamingText("");
    streamingMessageIDRef.current = "";
    setStatus(i18n.t("agentWorkspace.ready"));
    requestAnimationFrame(() => textareaRef.current?.focus());
  }

  function archiveSession(session: AgentSession, archived: boolean) {
    if (busy || sessionMutationID || !localHydrationReady) return;
    setSessions((current) => current.map((item) => item.id === session.id ? { ...item, archived, updatedAt: Date.now() } : item));
    if (archived && session.id === activeSession.id) {
      const next = sessions.find((item) => item.id !== session.id && !item.archived);
      if (next) setActiveSessionId(next.id);
      else createSession();
    }
  }

  function deleteSession(session: AgentSession) {
    if (busy || sessionMutationID || !localHydrationReady) return;
    if (!window.confirm(i18n.t("agentWorkspace.deleteConfirm", { name: sessionLabel(session) }))) return;
    setSessionMutationID(session.id);
    const serverSessionId = session.serverSessionId || `session-${session.id}`;
    const next = sessions.find((item) => item.id !== session.id && !item.archived) ?? sessions.find((item) => item.id !== session.id);
    const deleted = deletedServerSessionIds.includes(serverSessionId) ? deletedServerSessionIds : [...deletedServerSessionIds, serverSessionId];
    let remaining = sessions.filter((item) => item.id !== session.id);
    let nextActiveSessionId = activeSessionId;
    if (session.id === activeSession.id && next) {
      nextActiveSessionId = next.id;
    } else if (session.id === activeSession.id) {
      const replacement = createAgentSession();
      remaining = [replacement, ...remaining];
      nextActiveSessionId = replacement.id;
    }
    setDeletedServerSessionIds(deleted);
    setSessions(remaining);
    setActiveSessionId(nextActiveSessionId);
    void writeStoredAgent({ activeSessionId: nextActiveSessionId, sessions: remaining, deletedServerSessionIds: deleted }, ledgerScope);
    setSessionMutationID("");
    showToast("success", i18n.t("agentWorkspace.sessionDeleted"));
    void apiFetch(`/api/ai/agent/sessions/${encodeURIComponent(serverSessionId)}`, { method: "DELETE" }, { kind: "write" }).catch(() => undefined);
  }

  function selectSession(sessionId: string) {
    if (busy || !localHydrationReady) return;
    setMobileSessionListOpen(false);
    if (sessionId === activeSession.id) return;
    setActiveSessionId(sessionId);
    setInput("");
    setStreamingText("");
    streamingMessageIDRef.current = "";
    setStatus(i18n.t("agentWorkspace.ready"));
  }

  useEffect(() => {
    let cancelled = false;
    void readStoredAgent(ledgerScope).then((local) => {
      if (cancelled || !local?.sessions.length) return;
      setSessions(local.sessions);
      setActiveSessionId(local.activeSessionId);
      setDeletedServerSessionIds(local.deletedServerSessionIds);
    }).finally(() => {
      if (!cancelled) setLocalHydrationReady(true);
    });
    return () => {
      cancelled = true;
    };
  }, [ledgerScope]);

  useEffect(() => {
    if (!localHydrationReady) return;
    void writeStoredAgent({ activeSessionId, sessions, deletedServerSessionIds }, ledgerScope);
  }, [activeSessionId, deletedServerSessionIds, ledgerScope, localHydrationReady, sessions]);

  useEffect(() => {
    if (!shouldHydrateAgentTimeline(activeSession, localHydrationReady)) return;
    const hydrateMissingTimeline = () => void loadTimelinePage(sessionId);
    hydrateMissingTimeline();
    window.addEventListener("online", hydrateMissingTimeline);
    return () => window.removeEventListener("online", hydrateMissingTimeline);
  // sessionId changes after a legacy session receives its durable server id.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeSessionId, localHydrationReady, sessionId]);

  useEffect(() => {
    if (!localHydrationReady || !timelineNeedsServerRefresh(timeline)) return;
    const timer = window.setTimeout(() => void loadTimelinePage(sessionId), AGENT_TIMELINE_REFRESH_MS);
    return () => window.clearTimeout(timer);
  }, [localHydrationReady, sessionId, timeline]);

  useEffect(() => {
    if (!localHydrationReady || !request || request.id === requestRef.current) return;
    requestRef.current = request.id;
    setOpen(true);
    const prompt = request.prompt?.trim() ?? "";
    if (!prompt) {
      requestAnimationFrame(() => textareaRef.current?.focus());
      return;
    }
    if (request.autoSubmit) {
      window.setTimeout(() => void sendRef.current(prompt), 0);
    } else {
      setInput(prompt);
      requestAnimationFrame(() => textareaRef.current?.focus());
    }
  }, [localHydrationReady, request]);

  useEffect(() => {
    if (!open) return;
    requestAnimationFrame(() => {
      const scrollRef = presentation === "page" ? desktopScrollRef : window.matchMedia("(min-width: 768px)").matches ? (desktopFullscreen ? fullscreenScrollRef : desktopScrollRef) : mobileScrollRef;
      scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
    });
  }, [desktopFullscreen, open, presentation, timeline, streamingText, status]);

  useEffect(() => {
    if (presentation === "page" || !open || (!desktopFullscreen && window.matchMedia("(min-width: 768px)").matches)) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previousOverflow;
    };
  }, [desktopFullscreen, open, presentation]);

  useEffect(() => {
    if (!open) {
      setDesktopFullscreen(false);
      setMobileSessionListOpen(false);
    }
  }, [open]);

  const conversation = timeline.filter((item): item is MessageItem => item.kind === "message");
  const hasConversation = conversation.some((message) => message.role === "user");

  async function loadTimelinePage(serverSessionId: string, before?: number) {
    if (!serverSessionId) return;
    setTimelinePagination((current) => ({ ...current, [serverSessionId]: { loading: true, nextBefore: current[serverSessionId]?.nextBefore ?? null } }));
    const query = before ? `?before=${before}` : "";
    const page = await fetchAgentTimelinePage(() => apiFetch(`/api/ai/agent/sessions/${encodeURIComponent(serverSessionId)}/timeline${query}`, undefined, { kind: "read" }));
    if (!page) {
      setTimelinePagination((current) => ({ ...current, [serverSessionId]: { loading: false, nextBefore: current[serverSessionId]?.nextBefore ?? null } }));
      return;
    }
    setSessions((current) => current.map((session) => {
      if ((session.serverSessionId || `session-${session.id}`) !== serverSessionId) return session;
      if (!before) {
        const title = timelineTitle(page.items) || session.title;
        return { ...session, title, timelineState: "available", timeline: reconcileAgentTimeline(page.items, session.timeline) };
      }
      const known = new Set(session.timeline.map((item) => item.id));
      return { ...session, timeline: [...page.items.filter((item) => !known.has(item.id)), ...session.timeline] };
    }));
    setTimelinePagination((current) => ({ ...current, [serverSessionId]: { loading: false, nextBefore: page.nextBefore } }));
  }

  async function sendMessage(text: string) {
    const prompt = text.trim();
    if (!prompt || busy || !localHydrationReady) return;
    if (containsSensitiveAgentInput(prompt)) {
      showToast("error", i18n.t("agentWorkspace.sensitiveInputWarning"));
      return;
    }
    setOpen(true);
    setBusy(true);
    setInput("");
    setStreamingText("");
    streamingMessageIDRef.current = nextID();
    setStatus(i18n.t("agentWorkspace.connecting"));
    updateTimeline((current) => [...current, { kind: "message", id: nextID(), role: "user", content: prompt }]);
    try {
      const response = await apiFetch("/api/ai/agent/turn", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId, message: prompt, context }),
      }, { kind: "write" });
      const final = await consumeStream(response);
      finishTurn(final);
    } catch (error) {
      const message = error instanceof Error ? error.message : i18n.t("agentWorkspace.agentRequestFailed");
      const messageID = streamingMessageIDRef.current || nextID();
      setStreamingText("");
      updateTimeline((current) => [...current, { kind: "message", id: messageID, role: "assistant", content: i18n.t("agentWorkspace.agentProcessingFailed", { message }) }]);
      setStatus(i18n.t("agentWorkspace.processingFailed"));
      showToast("error", message);
    } finally {
      setBusy(false);
      setStreamingText("");
      streamingMessageIDRef.current = "";
    }
  }

  sendRef.current = sendMessage;

  async function consumeStream(response: Response) {
    return readLedgerAgentStream(response, {
      onMessageDelta: setStreamingText,
      onStatus: setStatus,
      onTool: upsertTool,
      onArtifact: (artifact) => updateTimeline((current) => [...current, { kind: "artifact", id: artifact.id, artifact }]),
    });
  }

  function finishTurn(final: AgentFinal) {
    updateActiveSession((session) => ({ ...session, serverSessionId: final.sessionId, updatedAt: Date.now() }));
    setStatus(final.status === "cancelled" ? i18n.t("agentWorkspace.cancelled") : i18n.t("agentWorkspace.ready"));
    const message = final.message.trim();
    if (message) {
      const messageID = streamingMessageIDRef.current || nextID();
      setStreamingText("");
      updateTimeline((current) => [...current, { kind: "message", id: messageID, role: "assistant", content: message }]);
    }
    void loadTimelinePage(final.sessionId);
    if (final.refreshLedger) {
      showToast("success", i18n.t("agentWorkspace.ledgerUpdated"));
      void onChanged();
    }
  }

  function upsertTool(tool: AgentToolEvent) {
    if (agentToolNeedsSensitiveUnlock(tool.error)) requestAgentSensitiveUnlock();
    updateTimeline((current) => {
      const index = current.findIndex((item) => item.kind === "tool" && item.tool.id === tool.id);
      if (index < 0) return [...current, { kind: "tool", id: tool.id, tool }];
      return current.map((item, itemIndex) => itemIndex === index && item.kind === "tool" ? { ...item, tool: { ...item.tool, ...tool } } : item);
    });
  }

  function handleSubmit() {
    void sendMessage(input);
  }

  function selectStarter(starter: AgentStarter) {
    if (busy) return;
    setInput(i18n.t(starter.promptKey));
    requestAnimationFrame(() => textareaRef.current?.focus());
  }

  const panel = (className: string, scrollContainerRef: RefObject<HTMLDivElement | null>) => (
    <section className={className}
      aria-label={i18n.t("agentWorkspace.globalAgentLabel")}
    >
      <header className="flex shrink-0 items-center justify-between border-b border-line bg-panel px-3 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] md:py-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-md bg-brand text-paper"><Bot className="h-4 w-4" /></span>
          <div className="min-w-0">
            <h2 className="truncate text-sm font-semibold text-ink">{i18n.t("agentWorkspace.title")}</h2>
            <p className="truncate text-xs text-stone">{status}</p>
          </div>
        </div>
        <div className="flex items-center gap-1">
          <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag md:h-8 md:w-8 md:hidden" title={i18n.t("agentWorkspace.viewSessionHistory")} aria-label={i18n.t("agentWorkspace.viewSessionHistory")} onClick={() => setMobileSessionListOpen(true)}><History className="h-4 w-4" /></button>
          {presentation === "dock" && <button type="button" className="hidden h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag md:grid" title={desktopFullscreen ? i18n.t("agentWorkspace.exitFullscreen") : i18n.t("agentWorkspace.fullscreenView")} aria-label={desktopFullscreen ? i18n.t("agentWorkspace.exitFullscreen") : i18n.t("agentWorkspace.fullscreenView")} onClick={() => setDesktopFullscreen((current) => !current)}>{desktopFullscreen ? <Minimize2 className="h-4 w-4" /> : <Maximize2 className="h-4 w-4" />}</button>}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag disabled:opacity-45 md:h-8 md:w-8" aria-label={i18n.t("agentWorkspace.manageSession")} title={i18n.t("agentWorkspace.manageSession")} disabled={busy || Boolean(sessionMutationID)}><MoreHorizontal className="h-4 w-4" /></button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="border-line bg-paper text-ink">
              <DropdownMenuItem onSelect={() => archiveSession(activeSession, !activeSession.archived)}>{activeSession.archived ? <ArchiveRestore className="h-4 w-4" /> : <Archive className="h-4 w-4" />}{activeSession.archived ? i18n.t("agentWorkspace.unarchiveSession") : i18n.t("agentWorkspace.archiveSession")}</DropdownMenuItem>
              <DropdownMenuItem variant="destructive" onSelect={() => void deleteSession(activeSession)}><Trash2 className="h-4 w-4" />{i18n.t("agentWorkspace.deleteSession")}</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
          <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag md:h-8 md:w-8" title={i18n.t("agentWorkspace.newSession")} aria-label={i18n.t("agentWorkspace.newSession")} onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button>
          {presentation === "page" && <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag md:hidden" title={i18n.t("agentWorkspace.close")} aria-label={i18n.t("agentWorkspace.close")} onClick={() => onNavigate("/home")}><X className="h-4 w-4" /></button>}
          {presentation === "dock" && <button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-stone hover:bg-tag" title={i18n.t("agentWorkspace.close")} aria-label={i18n.t("agentWorkspace.close")} onClick={() => setOpen(false)}><X className="h-4 w-4" /></button>}
        </div>
      </header>

      <div ref={scrollContainerRef} className="min-h-0 min-w-0 max-w-full flex-1 overflow-y-auto overflow-x-hidden px-3 py-4 md:px-4">
        {!hasConversation && <div className={`mb-4 grid grid-cols-1 gap-2 sm:grid-cols-2 ${presentation === "page" ? "md:grid-cols-2" : "md:grid-cols-1"}`}>
          {suggestions.map((suggestion) => <button key={suggestion} type="button" className="min-h-11 rounded-md border border-line bg-panel px-3 py-2 text-left text-sm text-olive hover:bg-tag" onClick={() => void sendMessage(suggestion)} disabled={busy}>{suggestion}</button>)}
        </div>}
        <div className="min-w-0 max-w-full space-y-3">
          {timelinePagination[sessionId]?.nextBefore != null && <button type="button" className="w-full rounded-md border border-line bg-panel px-3 py-2 text-xs text-olive hover:bg-tag disabled:opacity-50" onClick={() => void loadTimelinePage(sessionId, timelinePagination[sessionId].nextBefore ?? undefined)} disabled={busy || timelinePagination[sessionId]?.loading}>{timelinePagination[sessionId]?.loading ? i18n.t("agentWorkspace.loadEarlier") : i18n.t("agentWorkspace.loadEarlierPage", { count: AGENT_TIMELINE_PAGE_SIZE })}</button>}
          {timelinePagination[sessionId]?.loading && timeline.length === 0 && <div className="flex items-center gap-2 py-2 text-sm text-stone"><LoaderCircle className="h-4 w-4 animate-spin" />{i18n.t("agentWorkspace.loadingTimeline")}</div>}
          {timeline.map((item) => {
            if (item.kind === "message") return <MessageBubble key={item.id} item={item} />;
            if (item.kind === "tool" && liveToolIDs.has(item.id)) return null;
            if (item.kind === "tool") return <ToolCard key={item.id} tool={item.tool} expanded={Boolean(expandedTools[item.id])} onToggle={() => setExpandedTools((current) => ({ ...current, [item.id]: !current[item.id] }))} />;
            return <ArtifactCard key={item.id} artifact={item.artifact} onApplyBQL={onApplyBQL} onNavigate={onNavigate} />;
          })}
          {busy && <AgentWorkStatus
            status={status}
            tools={liveTools}
            streamingText={streamingText}
            expandedTools={expandedTools}
            onToggleTool={(id) => setExpandedTools((current) => ({ ...current, [id]: !current[id] }))}
          />}
        </div>
      </div>

      <footer className="shrink-0 border-t border-line bg-panel px-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)] pt-2 md:p-3">
        <div className="overflow-hidden rounded-md border border-line bg-paper focus-within:ring-2 focus-within:ring-brand/25">
          <textarea
            ref={textareaRef}
            className="block max-h-32 min-h-14 w-full resize-none bg-transparent px-3 py-2.5 text-sm leading-relaxed text-ink outline-none placeholder:text-stone"
            value={input}
            onChange={(event) => setInput(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                handleSubmit();
              }
            }}
            placeholder={i18n.t("agentWorkspace.inputPlaceholder")}
            disabled={busy}
          />
          <div className="flex items-center justify-between border-t border-line px-2 py-2">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button type="button" className="inline-flex h-8 min-w-0 items-center gap-1.5 rounded-md px-2 text-xs font-medium text-olive active:scale-95 hover:bg-tag disabled:opacity-45" disabled={busy} aria-label={i18n.t("agentWorkspace.openTools")}>
                  <SlidersHorizontal className="h-3.5 w-3.5 text-brand" />{i18n.t("agentWorkspace.tools")}
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-72 border-line bg-paper text-ink">
                <DropdownMenuLabel className="text-xs text-stone">{i18n.t("agentWorkspace.chooseStarter")}</DropdownMenuLabel>
                <DropdownMenuSeparator className="bg-line" />
                {agentStarters.map((starter) => <DropdownMenuItem key={starter.labelKey} className="items-start gap-2.5 py-2.5 focus:bg-tag focus:text-ink" onSelect={() => selectStarter(starter)}>
                  <span className="mt-0.5 text-brand">{starter.icon}</span>
                  <span><span className="block text-sm font-medium">{i18n.t(starter.labelKey)}</span><span className="mt-0.5 block text-xs text-stone">{i18n.t(starter.descriptionKey)}</span></span>
                </DropdownMenuItem>)}
              </DropdownMenuContent>
            </DropdownMenu>
            <div className="flex items-center gap-1.5">
              <span className="hidden text-[11px] text-stone sm:inline">{i18n.t("agentWorkspace.enterToSend")}</span>
              <button type="button" className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-brand text-paper transition-transform active:scale-95 disabled:opacity-45" onClick={handleSubmit} disabled={busy || !input.trim()} aria-label={i18n.t("agentWorkspace.send")} title={i18n.t("agentWorkspace.send")}><Send className="h-4 w-4" /></button>
            </div>
          </div>
        </div>
      </footer>
    </section>
  );

  const mobileSessionList = createPortal(
    <section className="fixed inset-0 z-[110] flex flex-col overflow-hidden bg-paper md:hidden" aria-label={i18n.t("agentWorkspace.mobileSessionHistory")}>
      <header className="flex shrink-0 items-center justify-between border-b border-line bg-panel px-3 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)]">
        <div><h2 className="text-sm font-semibold text-ink">{i18n.t("agentWorkspace.sessionHistory")}</h2><p className="text-xs text-stone">{i18n.t("agentWorkspace.sessionCount", { count: sessions.length - archivedSessionCount })}</p></div>
        <div className="flex items-center gap-1">
          {archivedSessionCount > 0 && <button type="button" className="h-9 rounded-md px-2 text-xs text-stone hover:bg-tag" onClick={() => setShowArchivedSessions((current) => !current)}>{showArchivedSessions ? i18n.t("agentWorkspace.hideArchived") : i18n.t("agentWorkspace.archivedCount", { count: archivedSessionCount })}</button>}
          <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title={i18n.t("agentWorkspace.newSession")} aria-label={i18n.t("agentWorkspace.newSession")} onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button>
          <button type="button" className="grid h-9 w-9 place-items-center rounded-md border border-line text-stone hover:bg-tag" title={i18n.t("agentWorkspace.backToChat")} aria-label={i18n.t("agentWorkspace.backToChat")} onClick={() => setMobileSessionListOpen(false)}><X className="h-4 w-4" /></button>
        </div>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto p-3 pb-[calc(env(safe-area-inset-bottom)+0.75rem)]">
        {[...sidebarSessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-2 w-full rounded-md border px-3 py-3 text-left transition ${session.id === activeSession.id ? "border-brand bg-brand text-paper" : "border-line bg-panel text-ink active:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}>
          <span className="block truncate text-sm font-medium">{session.archived && i18n.t("agentWorkspace.archivedPrefix")}{sessionLabel(session)}</span>
          <span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · {i18n.t("agentWorkspace.loadedCount", { count: session.timeline.length })}</span>
        </button>)}
      </div>
    </section>,
    document.body,
  );

  if (presentation === "page") {
    const pageWorkspace = <section className={`ledger-agent-page flex min-h-0 min-w-0 max-w-full overflow-hidden bg-paper ${desktopViewport ? "h-dvh" : "fixed inset-0 z-40 h-dvh"}`} aria-label={i18n.t("agentWorkspace.agentWorkspaceLabel")}>
    <aside className="hidden min-h-0 w-72 shrink-0 flex-col border-r border-line bg-panel md:flex" aria-label={i18n.t("agentWorkspace.agentSessionHistory")}>
      <div className="flex h-16 shrink-0 items-center justify-between border-b border-line px-4"><div><h2 className="text-sm font-semibold text-ink">{i18n.t("agentWorkspace.sessionHistory")}</h2><p className="text-xs text-stone">{i18n.t("agentWorkspace.sessionCount", { count: sessions.length - archivedSessionCount })}</p></div><div className="flex items-center gap-1">{archivedSessionCount > 0 && <button type="button" className="h-8 rounded-md px-2 text-xs text-stone hover:bg-tag" onClick={() => setShowArchivedSessions((current) => !current)}>{showArchivedSessions ? i18n.t("agentWorkspace.hideArchived") : i18n.t("agentWorkspace.archivedCount", { count: archivedSessionCount })}</button>}<button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title={i18n.t("agentWorkspace.newSession")} aria-label={i18n.t("agentWorkspace.newSession")} onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button></div></div>
      <div className="min-h-0 flex-1 overflow-y-auto p-2">{[...sidebarSessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-1 w-full rounded-md px-3 py-2.5 text-left transition ${session.id === activeSession.id ? "bg-brand text-paper" : "text-ink hover:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}><span className="block truncate text-sm font-medium">{session.archived && i18n.t("agentWorkspace.archivedPrefix")}{sessionLabel(session)}</span><span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · {i18n.t("agentWorkspace.loadedCount", { count: session.timeline.length })}</span></button>)}</div>
    </aside>
    {panel("flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden bg-paper", desktopScrollRef)}
    </section>;
    return <>{desktopViewport ? pageWorkspace : createPortal(pageWorkspace, document.body)}{mobileSessionListOpen && mobileSessionList}</>;
  }

  return <>
    <aside className={`ledger-agent-dock hidden min-w-0 ${desktopFullscreen ? "" : "md:block"}`} data-open={open && !desktopFullscreen ? "true" : "false"} aria-label={i18n.t("agentWorkspace.agentSidebar")}>
      {open && !desktopFullscreen && panel("flex h-full w-full min-w-0 flex-col overflow-hidden bg-paper", desktopScrollRef)}
    </aside>
    {open && desktopFullscreen && createPortal(
      <section className="fixed inset-0 z-[100] hidden overflow-hidden bg-paper md:flex" aria-label={i18n.t("agentWorkspace.agentFullscreen")}>
        <aside className="flex w-72 shrink-0 flex-col border-r border-line bg-panel" aria-label={i18n.t("agentWorkspace.agentSessionHistory")}>
          <div className="flex h-16 shrink-0 items-center justify-between border-b border-line px-4">
            <div><h2 className="text-sm font-semibold text-ink">{i18n.t("agentWorkspace.sessionHistory")}</h2><p className="text-xs text-stone">{i18n.t("agentWorkspace.sessionCount", { count: sessions.length - archivedSessionCount })}</p></div>
            <div className="flex items-center gap-1">{archivedSessionCount > 0 && <button type="button" className="h-8 rounded-md px-2 text-xs text-stone hover:bg-tag" onClick={() => setShowArchivedSessions((current) => !current)}>{showArchivedSessions ? i18n.t("agentWorkspace.hideArchived") : i18n.t("agentWorkspace.archivedCount", { count: archivedSessionCount })}</button>}<button type="button" className="grid h-8 w-8 place-items-center rounded-md border border-line text-brand hover:bg-tag disabled:opacity-50" title={i18n.t("agentWorkspace.newSession")} aria-label={i18n.t("agentWorkspace.newSession")} onClick={createSession} disabled={busy}><Plus className="h-4 w-4" /></button></div>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto p-2">
            {[...sidebarSessions].sort((left, right) => right.updatedAt - left.updatedAt).map((session) => <button key={session.id} type="button" className={`mb-1 w-full rounded-md px-3 py-2.5 text-left transition ${session.id === activeSession.id ? "bg-brand text-paper" : "text-ink hover:bg-tag"}`} onClick={() => selectSession(session.id)} disabled={busy}>
              <span className="block truncate text-sm font-medium">{session.archived && i18n.t("agentWorkspace.archivedPrefix")}{sessionLabel(session)}</span>
              <span className={`mt-1 block text-[11px] ${session.id === activeSession.id ? "text-paper/75" : "text-stone"}`}>{sessionTime(session)} · {i18n.t("agentWorkspace.loadedCount", { count: session.timeline.length })}</span>
            </button>)}
          </div>
        </aside>
        {panel("flex min-w-0 flex-1 flex-col overflow-hidden bg-paper", fullscreenScrollRef)}
      </section>,
      document.body
    )}
    {open && createPortal(panel("fixed inset-0 z-[90] flex min-w-0 max-w-full flex-col overflow-hidden bg-paper shadow-2xl md:hidden", mobileScrollRef), document.body)}
    {open && mobileSessionListOpen && mobileSessionList}
  </>;
}

function MessageBubble({ item }: { item: MessageItem }) {
  return <AgentMessageBubble role={item.role} content={item.content} />;
}

function AgentWorkStatus({ status, tools, streamingText, expandedTools, onToggleTool }: { status: string; tools: ToolItem[]; streamingText: string; expandedTools: Record<string, boolean>; onToggleTool: (id: string) => void }) {
  const completedTools = tools.filter((item) => item.tool.status === "completed").length;
  return <section className="min-w-0 overflow-hidden rounded-md border border-line bg-panel" aria-live="polite" aria-label={i18n.t("agentWorkspace.workingStatus")}>
    <div className="flex items-center gap-3 px-3 py-2.5">
      <span className="grid h-8 w-8 shrink-0 place-items-center rounded-md bg-brand/10 text-brand"><LoaderCircle className="h-4 w-4 animate-spin" /></span>
      <div className="min-w-0 flex-1">
        <div className="text-sm font-semibold text-ink">{i18n.t("agentWorkspace.agentWorking")}</div>
        <div className="truncate text-xs text-stone">{status}</div>
      </div>
      <span className="shrink-0 text-[11px] tabular-nums text-stone">{tools.length ? i18n.t("agentWorkspace.toolsProgress", { completed: completedTools, total: tools.length }) : i18n.t("agentWorkspace.preparing")}</span>
    </div>
    {tools.length > 0 && <div className="divide-y divide-line border-t border-line">
      {tools.map((item) => <AgentWorkTool key={item.id} item={item} expanded={Boolean(expandedTools[item.id])} onToggle={() => onToggleTool(item.id)} />)}
    </div>}
    {streamingText && <div className="border-t border-line bg-paper px-3 py-3">
      <div className="mb-1.5 text-[11px] font-semibold text-stone">{i18n.t("agentWorkspace.liveReply")}</div>
      <div className="min-w-0 break-words text-sm leading-relaxed text-ink [overflow-wrap:anywhere] [&_a]:break-all [&_code]:break-words [&_pre]:max-w-full [&_pre]:overflow-x-auto [&_pre]:rounded-sm [&_pre]:bg-panel [&_pre]:p-2"><MessageResponse>{streamingText}</MessageResponse></div>
    </div>}
  </section>;
}

function AgentWorkTool({ item, expanded, onToggle }: { item: ToolItem; expanded: boolean; onToggle: () => void }) {
  const tool = item.tool;
  return <div className="min-w-0 bg-paper/35">
    <button type="button" className="flex min-h-10 w-full items-center justify-between gap-3 px-3 py-2 text-left hover:bg-tag" onClick={onToggle}>
      <span className="flex min-w-0 items-center gap-2">{toolStateIcon(tool.status)}<span className="truncate text-sm font-medium text-ink">{tool.title}</span><span className="hidden truncate font-mono text-[10px] text-stone sm:inline">{tool.name}</span></span>
      {expanded ? <ChevronUp className="h-3.5 w-3.5 shrink-0 text-stone" /> : <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" />}
    </button>
    {agentToolNeedsSensitiveUnlock(tool.error) && <AgentUnlockNotice />}
    {expanded && <pre className="max-h-44 max-w-full overflow-auto border-t border-line px-3 py-2.5 text-[11px] leading-relaxed text-stone [overflow-wrap:anywhere]">{JSON.stringify(tool.error ? { error: tool.error } : tool.output ?? tool.input ?? {}, null, 2)}</pre>}
  </div>;
}

function toolStateIcon(status: AgentToolEvent["status"]) {
  return status === "running" ? <LoaderCircle className="h-3.5 w-3.5 shrink-0 animate-spin text-brand" /> : status === "completed" ? <Check className="h-3.5 w-3.5 shrink-0 text-[var(--success)]" /> : <Ban className="h-3.5 w-3.5 shrink-0 text-[var(--danger)]" />;
}

function ToolCard({ tool, expanded, onToggle }: { tool: AgentToolEvent; expanded: boolean; onToggle: () => void }) {
  return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel">
    <button type="button" className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left" onClick={onToggle}>
      <span className="flex min-w-0 items-center gap-2">{toolStateIcon(tool.status)}<span className="truncate text-sm font-medium text-ink">{tool.title}</span><span className="truncate font-mono text-[10px] text-stone">{tool.name}</span></span>
      {expanded ? <ChevronUp className="h-3.5 w-3.5 shrink-0 text-stone" /> : <ChevronDown className="h-3.5 w-3.5 shrink-0 text-stone" />}
    </button>
    {agentToolNeedsSensitiveUnlock(tool.error) && <AgentUnlockNotice />}
    {expanded && <pre className="max-h-44 max-w-full overflow-auto border-t border-line p-3 text-[11px] leading-relaxed text-stone [overflow-wrap:anywhere]">{JSON.stringify(tool.error ? { error: tool.error } : tool.output ?? tool.input ?? {}, null, 2)}</pre>}
  </div>;
}

function AgentUnlockNotice() {
  return <div className="border-t border-line bg-[var(--selected-bg)] px-3 py-3">
    <div className="flex min-w-0 items-start gap-2 text-sm text-ink"><LockKeyhole className="mt-0.5 h-4 w-4 shrink-0 text-brand" /><span>{i18n.t("agentWorkspace.toolNeedsUnlock")}</span></div>
  </div>;
}

function ArtifactCard({ artifact, onApplyBQL, onNavigate }: { artifact: AgentArtifact; onApplyBQL: (query: string) => void; onNavigate: (path: string) => void }) {
  if (artifact.type === "bql_query") {
    const query = objectString(artifact.data, "query");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel">
      <div className="flex items-center justify-between border-b border-line px-3 py-2"><span className="text-sm font-semibold text-ink">{artifact.title}</span><button type="button" className="inline-flex h-8 items-center gap-1.5 rounded-md bg-brand px-2.5 text-xs text-paper" onClick={() => onApplyBQL(query)} disabled={!query}><Play className="h-3.5 w-3.5" />{i18n.t("agentWorkspace.apply")}</button></div>
      <pre className="max-h-56 overflow-auto whitespace-pre-wrap p-3 font-mono text-[11px] leading-relaxed text-olive">{query}</pre>
    </div>;
  }
  if (artifact.type === "table") return <BQLTableCard title={artifact.title} result={artifact.data as BQLResult} />;
  if (artifact.type === "chart") {
    const data = artifact.data as { kind?: string; result?: BQLResult };
    return data.result ? <BQLChartCard title={artifact.title} kind={data.kind ?? "bar"} result={data.result} /> : null;
  }
  if (artifact.type === "transaction_change") {
    const original = objectString(artifact.data, "original");
    const replacement = objectString(artifact.data, "replacement");
    const reason = objectString(artifact.data, "reason");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel">
      <h3 className="border-b border-line px-3 py-2 text-sm font-semibold text-ink">{artifact.title}</h3>
      <div className="grid divide-y divide-line sm:grid-cols-2 sm:divide-x sm:divide-y-0">
        <div className="min-w-0 p-3"><div className="mb-1.5 text-xs font-medium text-stone">{i18n.t("agentWorkspace.originalBeancount")}</div><pre className="max-h-56 overflow-auto whitespace-pre-wrap rounded-md bg-paper p-2.5 font-mono text-[11px] leading-relaxed text-ink">{original}</pre></div>
        <div className="min-w-0 p-3"><div className="mb-1.5 text-xs font-medium text-stone">{replacement ? i18n.t("agentWorkspace.proposedReplacement") : i18n.t("agentWorkspace.proposedOperation")}</div>{replacement ? <pre className="max-h-56 overflow-auto whitespace-pre-wrap rounded-md bg-paper p-2.5 font-mono text-[11px] leading-relaxed text-ink">{replacement}</pre> : <div className="rounded-md bg-paper p-2.5 text-sm text-ink">{i18n.t("agentWorkspace.deleteThisTransaction")}{reason ? `：${reason}` : ""}</div>}</div>
      </div>
    </div>;
  }
  if (artifact.type === "transaction_draft") {
    const entries = objectArray<ParsedTransaction>(artifact.data, "entries");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {entries.length}</h3><div className="mt-2 space-y-2">{entries.map((entry, index) => <div key={`${entry.date}-${entry.payee}-${index}`} className="rounded-md border border-line bg-paper p-2.5"><div className="flex min-w-0 items-center justify-between gap-3 text-sm"><strong className="truncate text-ink">{entry.date} {entry.payee}</strong><span className="shrink-0 text-stone">{entry.postings[0]?.amount} {entry.postings[0]?.currency}</span></div><div className="mt-1 truncate text-xs text-stone">{entry.narration || entry.postings.map((posting) => posting.account).join(" · ")}</div></div>)}</div></div>;
  }
  if (artifact.type === "account_draft") {
    const operations = objectArray<AccountOperation>(artifact.data, "operations");
    return <div className="rounded-md border border-line bg-panel p-3"><h3 className="text-sm font-semibold text-ink">{artifact.title} · {operations.length}</h3><div className="mt-2 divide-y divide-line border-y border-line">{operations.map((operation, index) => <div key={`${operation.kind}-${operation.account}-${index}`} className="flex items-center justify-between gap-3 py-2 text-sm"><span className="min-w-0 truncate text-ink">{operation.account}</span><span className="shrink-0 text-xs uppercase text-stone">{operation.kind}</span></div>)}</div></div>;
  }
  if (artifact.type === "memory_draft") {
    const kind = objectString(artifact.data, "kind");
    const title = objectString(artifact.data, "title");
    const instruction = objectString(artifact.data, "instruction");
    return <div className="min-w-0 max-w-full overflow-hidden rounded-md border border-line bg-panel p-3"><div className="flex items-start gap-2"><Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-brand" /><div className="min-w-0"><h3 className="text-sm font-semibold text-ink">{artifact.title}</h3><p className="mt-1 text-xs text-stone">{memoryKindLabel(kind)}{title ? ` · ${title}` : ""}</p></div></div>{instruction && <p className="mt-2 break-words text-sm leading-relaxed text-olive">{instruction}</p>}</div>;
  }
  if (artifact.type === "navigation") {
    const path = objectString(artifact.data, "path");
    return <button type="button" className="flex w-full items-center justify-between rounded-md border border-line bg-panel px-3 py-2.5 text-sm text-ink hover:bg-tag" onClick={() => onNavigate(path)} disabled={!path}><span>{artifact.title}</span><ExternalLink className="h-4 w-4 text-stone" /></button>;
  }
  return null;
}

function memoryKindLabel(kind: string) {
  switch (kind) {
    case "preference": return i18n.t("agentWorkspace.memoryPreference");
    case "category_rule": return i18n.t("agentWorkspace.memoryCategoryRule");
    case "account_alias": return i18n.t("agentWorkspace.memoryAccountAlias");
    case "recurring": return i18n.t("agentWorkspace.memoryRecurring");
    case "response_style": return i18n.t("agentWorkspace.memoryResponseStyle");
    default: return i18n.t("agentWorkspace.memory");
  }
}

function BQLTableCard({ title, result }: { title: string; result: BQLResult }) {
  if (!result?.columns || !result?.rows) return null;
  return <div className="overflow-hidden rounded-md border border-line bg-panel">
    <div className="flex items-center justify-between border-b border-line px-3 py-2"><span className="text-sm font-semibold text-ink">{title}</span><span className="text-xs text-stone">{i18n.t("agentWorkspace.resultRows", { count: result.rowCount })}</span></div>
    <div className="max-h-64 overflow-auto"><table className="min-w-full text-left text-xs"><thead className="sticky top-0 bg-tag text-stone"><tr>{result.columns.map((column) => <th key={column.name} className="whitespace-nowrap border-b border-line px-2.5 py-2 font-medium">{column.name}</th>)}</tr></thead><tbody>{result.rows.slice(0, 12).map((row, rowIndex) => <tr key={rowIndex} className="border-b border-line/70">{result.columns.map((column, columnIndex) => <td key={`${rowIndex}-${column.name}`} className="max-w-40 truncate whitespace-nowrap px-2.5 py-2 text-ink">{formatValue(row[columnIndex], column)}</td>)}</tr>)}</tbody></table></div>
  </div>;
}

function BQLChartCard({ title, kind, result }: { title: string; kind: string; result: BQLResult }) {
  const model = buildChartData(result);
  if (!model) return <BQLTableCard title={title} result={result} />;
  const data = kind === "pie" ? model.data.filter((item) => item.value > 0).slice(0, 10) : model.data.slice(0, 30);
  return <div className="rounded-md border border-line bg-panel">
    <div className="border-b border-line px-3 py-2 text-sm font-semibold text-ink">{title}</div>
    <div className="h-64 px-2 py-3"><ResponsiveContainer width="100%" height="100%">{kind === "pie" ? <PieChart><Tooltip /><Pie data={data} dataKey="value" nameKey="label" innerRadius="45%" outerRadius="75%">{data.map((item, index) => <Cell key={item.label} fill={chartColors[index % chartColors.length]} />)}</Pie></PieChart> : kind === "line" ? <LineChart data={data}><CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} /><XAxis dataKey="label" tick={{ fontSize: 10 }} tickLine={false} axisLine={false} /><YAxis tick={{ fontSize: 10 }} tickLine={false} axisLine={false} width={52} /><Tooltip /><Line type="monotone" dataKey="value" stroke="var(--chart-primary)" strokeWidth={2} dot={false} /></LineChart> : <BarChart data={data}><CartesianGrid stroke="var(--chart-grid)" strokeDasharray="3 3" vertical={false} /><XAxis dataKey="label" tick={{ fontSize: 10 }} tickLine={false} axisLine={false} /><YAxis tick={{ fontSize: 10 }} tickLine={false} axisLine={false} width={52} /><Tooltip /><Bar dataKey="value" fill="var(--chart-primary)" radius={[3, 3, 0, 0]} /></BarChart>}</ResponsiveContainer></div>
  </div>;
}

function buildChartData(result: BQLResult) {
  const valueIndex = result.columns.findIndex((column) => column.type === "money" || column.type === "number");
  const labelIndex = result.columns.findIndex((column, index) => index !== valueIndex && column.type !== "money" && column.type !== "number");
  if (valueIndex < 0 || labelIndex < 0) return null;
  const valueColumn = result.columns[valueIndex];
  const data = result.rows.map((row, index) => {
    const numeric = Number(row[valueIndex]);
    return {
      label: String(row[labelIndex] ?? i18n.t("agentWorkspace.rowLabel", { index: index + 1 })),
      value: normalizeBQLChartValue(numeric, valueColumn),
    };
  }).filter((item) => Number.isFinite(item.value));
  return data.length ? { data } : null;
}

export function normalizeBQLChartValue(value: number, column: BQLColumn) {
  return column.type === "money" ? value / 100 : value;
}

function formatValue(value: unknown, column: BQLColumn) {
  if (value == null) return "";
  if (typeof value === "number" && column.type === "money") return new Intl.NumberFormat("zh-CN", { minimumFractionDigits: 2 }).format(value / 100);
  if (typeof value === "number") return new Intl.NumberFormat("zh-CN").format(value);
  return String(value);
}

function objectString(value: unknown, key: string) {
  if (!value || typeof value !== "object") return "";
  const result = (value as Record<string, unknown>)[key];
  return typeof result === "string" ? result : "";
}

function objectArray<T>(value: unknown, key: string): T[] {
  if (!value || typeof value !== "object") return [];
  const result = (value as Record<string, unknown>)[key];
  return Array.isArray(result) ? result as T[] : [];
}

export function timelineNeedsServerRefresh(timeline: TimelineItem[]) {
  const last = timeline.at(-1);
  return Boolean(last && !(last.kind === "message" && last.role === "assistant"));
}

export function shouldHydrateAgentTimeline(session: AgentSession, localHydrationReady: boolean) {
  return localHydrationReady && session.timelineState === "missing";
}

export async function fetchAgentTimelinePage(request: () => Promise<Response>): Promise<AgentTimelinePage | null> {
  try {
    const response = await request();
    if (!response.ok) return null;
    return normalizeAgentTimelinePage(await response.json());
  } catch {
    return null;
  }
}

export function reconcileAgentTimeline(serverItems: TimelineItem[], currentItems: TimelineItem[]) {
  const currentMessages = currentItems.filter((item): item is MessageItem => item.kind === "message");
  const usedMessageIDs = new Set<string>();
  const reconciledServer = serverItems.map((item) => {
    if (item.kind !== "message") return item;
    const rendered = currentMessages.find((candidate) =>
      !usedMessageIDs.has(candidate.id) && candidate.role === item.role && candidate.content === item.content
    );
    if (!rendered) return item;
    usedMessageIDs.add(rendered.id);
    return { ...item, id: rendered.id };
  });
  const serverIDs = new Set(reconciledServer.map((item) => item.id));
  const overlap = currentItems.flatMap((item, index) => serverIDs.has(item.id) ? [index] : []);
  if (!overlap.length) return [...reconciledServer, ...currentItems];
  const firstOverlap = overlap[0];
  const lastOverlap = overlap.at(-1) ?? firstOverlap;
  const localPrefix = currentItems.slice(0, firstOverlap).filter((item) => !serverIDs.has(item.id));
  const optimisticSuffix = currentItems.slice(lastOverlap + 1).filter((item) => !serverIDs.has(item.id));
  return [...localPrefix, ...reconciledServer, ...optimisticSuffix];
}

export function normalizeAgentTimelinePage(value: unknown): AgentTimelinePage {
  const page = value && typeof value === "object" ? value as Record<string, unknown> : {};
  return {
    items: restoreTimeline(page.items),
    nextBefore: typeof page.nextBefore === "number" && Number.isInteger(page.nextBefore) && page.nextBefore > 0 ? page.nextBefore : null,
  };
}
