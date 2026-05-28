"use client";

import { BookOpen } from "lucide-react";
import { Source, Sources, SourcesContent, SourcesTrigger } from "@/components/ai-elements/sources";

export type LedgerAiSource = {
  title: string;
  description?: string;
  kind?: string;
  reference?: string;
  url?: string;
};

export function LedgerAiSourcesCard({ sources }: { sources: LedgerAiSource[] }) {
  const visibleSources = sources.filter((source) => source.title.trim()).slice(0, 8);
  if (visibleSources.length === 0) return null;

  return (
    <Sources className="mb-0 rounded-2xl border border-line bg-panel p-3 text-stone" defaultOpen={visibleSources.length <= 3}>
      <SourcesTrigger className="text-warm hover:text-brand" count={visibleSources.length}>
        <span className="font-medium">依据 {visibleSources.length} 项</span>
      </SourcesTrigger>
      <SourcesContent className="mt-2 w-full gap-1.5">
        {visibleSources.map((source, index) => (
          <Source
            key={`${source.title}-${index}`}
            className="rounded-xl bg-paper px-2.5 py-2 text-left text-stone hover:text-warm"
            href={source.url || undefined}
            onClick={(event) => {
              if (!source.url) event.preventDefault();
            }}
            title={source.title}
          >
            <BookOpen className="h-3.5 w-3.5 shrink-0 text-brand" />
            <span className="min-w-0">
              <span className="block truncate text-xs font-medium text-warm">{source.title}</span>
              {(source.description || source.reference) && (
                <span className="mt-0.5 block truncate text-[11px] text-stone">{source.description || source.reference}</span>
              )}
            </span>
          </Source>
        ))}
      </SourcesContent>
    </Sources>
  );
}
