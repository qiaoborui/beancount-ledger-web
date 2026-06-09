export function shouldConvertCmbCheckingPdf(file: File, provider: "auto" | "cmb-checking" | string) {
  const isPDF = file.name.toLowerCase().endsWith(".pdf") || file.type === "application/pdf";
  if (!isPDF) {
    return false;
  }
  return provider === "cmb-checking" || (provider === "auto" && file.name.includes("招商银行交易流水"));
}
