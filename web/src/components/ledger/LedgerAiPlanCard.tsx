"use client";

import {
  Plan,
  PlanAction,
  PlanContent,
  PlanDescription,
  PlanHeader,
  PlanTitle,
  PlanTrigger,
} from "@/components/ai-elements/plan";

export type LedgerAiPlan = {
  title?: string;
  description?: string;
  steps?: string[];
} | null;

export function LedgerAiPlanCard({ plan }: { plan: LedgerAiPlan }) {
  const steps = plan?.steps?.filter((step) => step.trim()) ?? [];
  if (!plan || (!plan.title && !plan.description && steps.length === 0)) return null;

  return (
    <Plan className="gap-3 rounded-2xl border-line bg-panel py-3 text-warm" defaultOpen>
      <PlanHeader className="gap-1 px-3">
        <PlanTitle className="text-sm">{plan.title || "处理计划"}</PlanTitle>
        {plan.description && <PlanDescription className="text-xs text-stone">{plan.description}</PlanDescription>}
        {steps.length > 0 && <PlanAction><PlanTrigger className="text-stone hover:bg-tag hover:text-warm" /></PlanAction>}
      </PlanHeader>
      {steps.length > 0 && (
        <PlanContent className="px-3">
          <ol className="space-y-1.5 text-xs leading-5 text-olive">
            {steps.map((step, index) => (
              <li key={`${step}-${index}`} className="grid grid-cols-[1.5rem_minmax(0,1fr)] gap-2">
                <span className="grid h-5 w-5 place-items-center rounded-full bg-tag text-[11px] text-brand">{index + 1}</span>
                <span>{step}</span>
              </li>
            ))}
          </ol>
        </PlanContent>
      )}
    </Plan>
  );
}
