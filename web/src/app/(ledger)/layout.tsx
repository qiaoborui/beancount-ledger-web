import { Suspense } from "react";
import { LedgerApp } from "@/components/LedgerApp";
import { AppSkeleton } from "@/components/ledger/AuthScreens";

export default function LedgerLayout() {
  return <Suspense fallback={<AppSkeleton />}><LedgerApp /></Suspense>;
}
