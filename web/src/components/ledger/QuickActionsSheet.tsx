import { Bot, FileUp, PenLine, RefreshCw, Scale } from "lucide-react";
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
  const run = (action: () => void) => {
    haptic(8);
    action();
    onClose();
  };
  const actions = [
    { label: "记一笔", description: "手动录入一条或多条分录", icon: PenLine, onClick: onManualEntry, primary: true },
    { label: "AI 记账", description: "用自然语言生成预览后确认写入", icon: Bot, onClick: onAiEntry },
    { label: "导入账单", description: "导入支付宝 / 微信等账单文件", icon: FileUp, onClick: onImport },
    { label: "对账", description: "核对实际余额并写入断言", icon: Scale, onClick: onReconcile },
    ...(pendingWriteCount > 0 && onSyncPendingWrites ? [{ label: syncingPendingWrites ? "同步中…" : "同步待写入", description: `${pendingWriteCount} 条离线记录待提交`, icon: RefreshCw, onClick: onSyncPendingWrites, disabled: syncingPendingWrites }] : []),
    { label: refreshing ? "刷新中…" : "刷新账本", description: "同步最新账本数据", icon: RefreshCw, onClick: onRefresh, disabled: refreshing },
  ];

  return <MobileSheet open={open} title="快捷操作" onClose={onClose} size="md" align="center" zIndexClassName="z-[105]">
    <div className="grid gap-3">
      {actions.map((action) => {
        const Icon = action.icon;
        return <Button key={action.label} type="button" variant={action.primary ? "default" : "outline"} disabled={action.disabled} onClick={() => run(action.onClick)} className={`h-auto justify-start gap-3 rounded-2xl border-line p-4 text-left ${action.primary ? "text-paper" : "bg-panel text-warm"}`}>
          <span className={`grid h-11 w-11 shrink-0 place-items-center rounded-2xl ${action.primary ? "bg-paper/15 text-paper" : "bg-paper text-brand"}`}><Icon className={`h-5 w-5 ${action.label === "刷新中…" || action.label === "同步中…" ? "animate-spin" : ""}`} /></span>
          <span className="min-w-0">
            <span className="block font-medium">{action.label}</span>
            <span className={`mt-0.5 block text-xs ${action.primary ? "text-paper/75" : "text-stone"}`}>{action.description}</span>
          </span>
        </Button>;
      })}
    </div>
  </MobileSheet>;
}
