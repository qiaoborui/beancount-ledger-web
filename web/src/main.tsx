import { StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { LedgerApp } from "@/components/LedgerApp";
import { PwaRegister } from "@/components/PwaRegister";
import { TooltipProvider } from "@/components/ui/tooltip";
import { installApiEndpointFetchInterceptor } from "@/lib/apiEndpoints";
import { purgeLegacySensitiveCacheStorage } from "@/lib/legacySensitiveCacheCleanup";
import "@/i18n";
import "@/app/globals.css";

installApiEndpointFetchInterceptor();
void purgeLegacySensitiveCacheStorage();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <PwaRegister />
    <Suspense fallback={null}>
      <TooltipProvider>
        <LedgerApp />
      </TooltipProvider>
    </Suspense>
  </StrictMode>,
);
