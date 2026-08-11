import { StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { SpeedInsights } from "@vercel/speed-insights/react";
import { LedgerApp } from "@/components/LedgerApp";
import { PwaRegister } from "@/components/PwaRegister";
import { TooltipProvider } from "@/components/ui/tooltip";
import { installApiEndpointFetchInterceptor } from "@/lib/apiEndpoints";
import { purgeLegacySensitiveCacheStorage } from "@/lib/legacySensitiveCacheCleanup";
import "@/i18n";
import "@/app/globals.css";

installApiEndpointFetchInterceptor();
void purgeLegacySensitiveCacheStorage();

const speedInsightsEnabled = import.meta.env.VITE_ENABLE_SPEED_INSIGHTS !== "false";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {speedInsightsEnabled && <SpeedInsights />}
    <PwaRegister />
    <Suspense fallback={null}>
      <TooltipProvider>
        <LedgerApp />
      </TooltipProvider>
    </Suspense>
  </StrictMode>,
);
