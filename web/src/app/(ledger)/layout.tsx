import { Suspense } from "react";
import { LedgerApp } from "@/components/LedgerApp";

export default function LedgerLayout() {
  return <Suspense fallback={null}><LedgerApp /></Suspense>;
}
