import { NextResponse } from "next/server";
import { apiHandler } from "@/lib/apiRoute";
import { requireAuthJson } from "@/lib/apiAuth";
import { createBillImportPreview, optionalProvider } from "@/lib/billImport";
import { rateLimit } from "@/lib/rateLimit";

export const POST = apiHandler(async (request: Request) => {
  const rateLimitError = rateLimit(request, { name: "imports.preview", limit: 10, windowMs: 60_000 });
  if (rateLimitError) return rateLimitError;

  const authError = await requireAuthJson();
  if (authError) return authError;

  const form = await request.formData();
  const provider = optionalProvider(form.get("provider"));
  const file = form.get("file");
  if (!(file instanceof File)) return NextResponse.json({ error: "file is required" }, { status: 400 });
  const alipayFundRounding = form.get("alipayFundRounding") === "true";
  const preview = await createBillImportPreview({ provider, file, alipayFundRounding });
  return NextResponse.json(preview);
}, { defaultStatus: 400 });
