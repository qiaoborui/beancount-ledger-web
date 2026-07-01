import { useEffect, useRef, useState } from "react";
import type { InvestmentLiveQuote } from "../types";

type QuoteMessage = {
  type?: string;
  data?: InvestmentLiveQuote[];
};

function investmentQuotesWebSocketURL() {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/api/ledger/investments/quotes/ws`;
}

export function useInvestmentQuoteStream(enabled: boolean) {
  const [quotes, setQuotes] = useState<Record<string, InvestmentLiveQuote>>({});
  const [connected, setConnected] = useState(false);
  const [lastUpdatedAt, setLastUpdatedAt] = useState<string>("");
  const [error, setError] = useState("");
  const enabledRef = useRef(enabled);
  enabledRef.current = enabled;

  useEffect(() => {
    if (!enabled || typeof window === "undefined") {
      setQuotes({});
      setConnected(false);
      setLastUpdatedAt("");
      setError("");
      return;
    }
    let socket: WebSocket | null = null;
    let closed = false;
    let reconnectTimer: number | null = null;
    let reconnectAttempt = 0;

    const scheduleReconnect = () => {
      setConnected(false);
      if (closed || !enabledRef.current) return;
      const delay = Math.min(30_000, 800 * 2 ** reconnectAttempt);
      reconnectAttempt += 1;
      reconnectTimer = window.setTimeout(connect, delay);
    };

    const connect = () => {
      if (closed || !enabledRef.current) return;
      socket = new WebSocket(investmentQuotesWebSocketURL());
      socket.addEventListener("open", () => {
        reconnectAttempt = 0;
        setConnected(true);
        setError("");
      });
      socket.addEventListener("message", (event) => {
        let parsed: QuoteMessage | null = null;
        try {
          parsed = JSON.parse(String(event.data)) as QuoteMessage;
        } catch {
          return;
        }
        if (parsed?.type !== "quotes" || !Array.isArray(parsed.data)) return;
        const next: Record<string, InvestmentLiveQuote> = {};
        for (const quote of parsed.data) {
          if (quote?.commodity && Number.isFinite(quote.amount)) next[quote.commodity] = quote;
        }
        setQuotes(next);
        setLastUpdatedAt(new Date().toISOString());
        const providerError = parsed.data.find((quote) => quote.error)?.error ?? "";
        setError(providerError);
      });
      socket.addEventListener("close", scheduleReconnect);
      socket.addEventListener("error", () => {
        setError("行情连接中断，正在重连");
        socket?.close();
      });
    };

    connect();
    return () => {
      closed = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, [enabled]);

  return { quotes, connected, lastUpdatedAt, error };
}
