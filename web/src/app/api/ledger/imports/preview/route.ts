import { NextResponse } from "next/server";
import { requireAuthJson } from "@/lib/apiAuth";
import { assertProvider, createBillImportPreview } from "@/lib/billImport";

export async function POST(request: Request) {
  const authError = await requireAuthJson();
  if (authError) return authError;

  try {
    const form = await request.formData();
    const provider = assertProvider(form.get("provider"));
    const file = form.get("file");
    if (!(file instanceof File)) return NextResponse.json({ error: "file is required" }, { status: 400 });
    const alipayFundRounding = form.get("alipayFundRounding") === "true";
    const preview = await createBillImportPreview({ provider, file, alipayFundRounding });
    return NextResponse.json(preview);
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
  }
}
