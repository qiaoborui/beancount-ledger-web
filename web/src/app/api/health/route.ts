import fs from "node:fs";
import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { ledgerRoot, mainBeanPath, runtimeRoot } from "@/lib/ledgerPaths";

export const GET = apiHandler(async () => {
  const root = ledgerRoot();
  const main = mainBeanPath();
  const runtime = runtimeRoot();
  const ledgerRootExists = fs.existsSync(root);
  const mainBeanExists = fs.existsSync(main);
  const runtimeDirExists = fs.existsSync(runtime);
  const ok = ledgerRootExists && mainBeanExists;

  return NextResponse.json(
    {
      ok,
      uptimeSeconds: Math.round(process.uptime()),
      ledgerRootExists,
      mainBeanExists,
      runtimeDirExists,
    },
    { status: ok ? 200 : 503 },
  );
});
