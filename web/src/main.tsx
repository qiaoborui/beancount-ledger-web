import { StrictMode, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { SpeedInsights } from "@vercel/speed-insights/react";
import { LedgerApp } from "@/components/LedgerApp";
import { PwaRegister } from "@/components/PwaRegister";
import { TooltipProvider } from "@/components/ui/tooltip";
import { installApiEndpointFetchInterceptor } from "@/lib/apiEndpoints";
import "@/app/globals.css";

installApiEndpointFetchInterceptor();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <SpeedInsights />
    <PwaRegister />
    <Suspense fallback={null}>
      <TooltipProvider>
        <LedgerApp />
      </TooltipProvider>
    </Suspense>
  </StrictMode>,
);
