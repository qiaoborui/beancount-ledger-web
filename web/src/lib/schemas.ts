import { z } from "zod";

const AmountSchema = z.preprocess((value) => {
  if (typeof value === "number" && Number.isFinite(value)) return value.toFixed(2);
  if (typeof value === "string") {
    const normalized = value.trim().replace(/,/g, "").replace(/^¥/, "");
    const n = Number(normalized);
    if (Number.isFinite(n)) return n.toFixed(2);
    return normalized;
  }
  return value;
}, z.string().regex(/^-?\d+(\.\d{1,2})?$/));

export const PostingSchema = z.object({
  account: z.string().min(1),
  amount: AmountSchema,
  currency: z.string().regex(/^[A-Z][A-Z0-9._-]*$/),
  priceKind: z.enum(["unit", "total"]).optional(),
  priceAmount: z.string().regex(/^\d+(\.\d{1,6})?$/).optional(),
  priceCurrency: z.string().regex(/^[A-Z][A-Z0-9._-]*$/).optional(),
});

export const MetadataValueSchema = z.union([z.string(), z.number(), z.boolean()]);
export const MetadataSchema = z.record(z.string().regex(/^[a-z][a-zA-Z0-9_-]*$/), MetadataValueSchema);

export const ParsedTransactionSchema = z.object({
  kind: z.literal("transaction"),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  payee: z.string().min(1),
  narration: z.string().default(""),
  metadata: MetadataSchema.default({}),
  tags: z.array(z.string().regex(/^[A-Za-z0-9_-]+$/)).default([]),
  postings: z.array(PostingSchema).min(2),
  confidence: z.number().min(0).max(1),
  needsReview: z.boolean(),
  questions: z.array(z.string()).default([]),
});

export const ParsedTransactionsSchema = z.object({
  entries: z.array(ParsedTransactionSchema).min(1),
});

export const BalanceAssertionSchema = z.object({
  kind: z.literal("balance"),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  account: z.string().min(1),
  amount: AmountSchema,
  currency: z.string().regex(/^[A-Z][A-Z0-9._-]*$/),
});

export const LedgerEntrySchema = z.discriminatedUnion("kind", [
  ParsedTransactionSchema,
  BalanceAssertionSchema,
]);

export type MetadataValue = z.infer<typeof MetadataValueSchema>;
export type TransactionMetadata = z.infer<typeof MetadataSchema>;
export type Posting = z.infer<typeof PostingSchema>;
export type ParsedTransaction = z.infer<typeof ParsedTransactionSchema>;
export type ParsedTransactions = z.infer<typeof ParsedTransactionsSchema>;
export type BalanceAssertion = z.infer<typeof BalanceAssertionSchema>;
export type LedgerEntry = z.infer<typeof LedgerEntrySchema>;
