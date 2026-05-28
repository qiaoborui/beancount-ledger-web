"use client";

import {
  Confirmation,
  ConfirmationAccepted,
  ConfirmationAction,
  ConfirmationActions,
  ConfirmationRequest,
  ConfirmationTitle,
} from "@/components/ai-elements/confirmation";

export function LedgerAiConfirmationCard({
  id,
  title,
  description,
  confirmLabel,
  acceptedText,
  busy,
  onConfirm,
  onCancel,
}: {
  id: string;
  title: string;
  description: string;
  confirmLabel: string;
  acceptedText: string;
  busy: boolean;
  onConfirm: () => void | Promise<void>;
  onCancel: () => void;
}) {
  return (
    <Confirmation
      approval={{ id, approved: busy ? true : undefined }}
      className="rounded-2xl border-line bg-panel text-warm"
      state={busy ? "approval-responded" : "approval-requested"}
    >
      <ConfirmationTitle className="text-sm text-warm">
        <span className="font-medium">{title}</span>
        <span className="mt-0.5 block text-xs text-stone">{description}</span>
      </ConfirmationTitle>
      <ConfirmationRequest>
        <ConfirmationActions>
          <ConfirmationAction className="border-line bg-paper text-stone hover:bg-tag hover:text-warm" disabled={busy} variant="outline" onClick={onCancel}>
            清空草稿
          </ConfirmationAction>
          <ConfirmationAction className="bg-brand text-paper hover:bg-brandLight" disabled={busy} onClick={onConfirm}>
            {confirmLabel}
          </ConfirmationAction>
        </ConfirmationActions>
      </ConfirmationRequest>
      <ConfirmationAccepted>
        <div className="text-xs text-stone">{acceptedText}</div>
      </ConfirmationAccepted>
    </Confirmation>
  );
}
