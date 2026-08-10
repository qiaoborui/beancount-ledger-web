import { Bot, FileUp, PenLine, RefreshCw, Scale } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { haptic } from "./haptics";
import { MobileSheet } from "./MobileSheet";

type QuickActionsSheetProps = {
  open: boolean;
  refreshing?: boolean;
  pendingWriteCount?: number;
  syncingPendingWrites?: boolean;
  onClose: () => void;
  onManualEntry: () => void;
  onAiEntry: () => void;
  onImport: () => void;
  onReconcile: () => void;
  onRefresh: () => void;
  onSyncPendingWrites?: () => void;
};

export function QuickActionsSheet({ open, refreshing, pendingWriteCount = 0, syncingPendingWrites, onClose, onManualEntry, onAiEntry, onImport, onReconcile, onRefresh, onSyncPendingWrites }: QuickActionsSheetProps) {
  const { t } = useTranslation();
  const run = (action: () => void) => {
    haptic(8);
    action();
    onClose();
  };
  const actions = [
    { label: t("quickActions.record"), description: t("quickActions.recordDesc"), icon: PenLine, onClick: onManualEntry, primary: true },
    { label: t("quickActions.agent"), description: t("quickActions.agentDesc"), icon: Bot, onClick: onAiEntry },
    { label: t("quickActions.import"), description: t("quickActions.importDesc"), icon: FileUp, onClick: onImport },
    { label: t("quickActions.reconcile"), description: t("quickActions.reconcileDesc"), icon: Scale, onClick: onReconcile },
    ...(pendingWriteCount > 0 && onSyncPendingWrites ? [{ label: syncingPendingWrites ? t("quickActions.syncing") : t("quickActions.syncPending"), description: t("quickActions.syncPendingDesc", { count: pendingWriteCount }), icon: RefreshCw, onClick: onSyncPendingWrites, disabled: syncingPendingWrites }] : []),
    { label: refreshing ? t("quickActions.refreshing") : t("quickActions.refresh"), description: t("quickActions.refreshDesc"), icon: RefreshCw, onClick: onRefresh, disabled: refreshing },
  ];

  return <MobileSheet open={open} title={t("quickActions.title")} onClose={onClose} size="md" align="center" zIndexClassName="z-[105]">
    <div className="grid gap-3">
      {actions.map((action) => {
        const Icon = action.icon;
        return <Button key={action.label} type="button" variant={action.primary ? "default" : "outline"} disabled={action.disabled} onClick={() => run(action.onClick)} className={`h-auto justify-start gap-3 rounded-2xl border-line p-4 text-left ${action.primary ? "text-paper" : "bg-panel text-warm"}`}>
          <span className={`grid h-11 w-11 shrink-0 place-items-center rounded-2xl ${action.primary ? "bg-paper/15 text-paper" : "bg-paper text-brand"}`}><Icon className={`h-5 w-5 ${action.label === t("quickActions.refreshing") || action.label === t("quickActions.syncing") ? "animate-spin" : ""}`} /></span>
          <span className="min-w-0">
            <span className="block font-medium">{action.label}</span>
            <span className={`mt-0.5 block text-xs ${action.primary ? "text-paper/75" : "text-stone"}`}>{action.description}</span>
          </span>
        </Button>;
      })}
    </div>
  </MobileSheet>;
}
