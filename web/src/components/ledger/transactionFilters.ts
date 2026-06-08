import type { MetadataValue, Txn } from "./types";

export type TransactionFilterMatchMode = "exact" | "prefix";

export type TransactionFilterInput = {
  categoryQuery?: string;
  searchQuery?: string;
  metadataQuery?: string;
  matchMode?: TransactionFilterMatchMode;
};

type TransactionSearchEntry = {
  categoryAccounts: string[];
  text: string;
  metadata: string;
};

export function transactionKey(txn: Txn): string {
  return `${txn.source.file}:${txn.source.line}:${txn.source.hash ?? ""}`;
}

export function metadataPairs(txn: Txn): [string, MetadataValue][] {
  return Object.entries(txn.metadata ?? {}).filter(([, value]) => value !== "" && value != null);
}

export function metadataText(txn: Txn): string {
  return [
    ...metadataPairs(txn).map(([key, value]) => `${key}:${String(value)}`),
    ...(txn.tags ?? []).map((tag) => `#${tag}`),
  ].join(" ");
}

export function categoryAccounts(txn: Txn): string[] {
  return txn.postings
    .filter((posting) => posting.account.startsWith("Expenses:") || posting.account.startsWith("Income:"))
    .map((posting) => posting.account);
}

export function matchesMetadataQuery(txn: Txn, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  const pairs = metadataPairs(txn);
  const tags = txn.tags ?? [];

  return q.split(/\s+/).every((word) => {
    if (word.startsWith("#")) return tags.some((tag) => `#${tag}`.toLowerCase().includes(word));
    const exact = word.match(/^([a-z][a-z0-9_-]*):(.+)$/i);
    if (exact) {
      const [, key, value] = exact;
      return pairs.some(([k, v]) => k.toLowerCase() === key.toLowerCase() && String(v).toLowerCase().includes(value.toLowerCase()));
    }
    return metadataText(txn).toLowerCase().includes(word);
  });
}

function buildTransactionSearchEntry(txn: Txn): TransactionSearchEntry {
  return {
    categoryAccounts: categoryAccounts(txn).map((account) => account.toLowerCase()),
    text: [
      txn.payee,
      txn.narration,
      txn.date,
      ...txn.postings.map((posting) => posting.account),
      metadataText(txn),
    ].join(" ").toLowerCase(),
    metadata: metadataText(txn).toLowerCase(),
  };
}

export function filterTransactions(txns: Txn[], filters: TransactionFilterInput): Txn[] {
  const categoryQuery = (filters.categoryQuery ?? "").trim().toLowerCase();
  const searchWords = (filters.searchQuery ?? "").trim().toLowerCase().split(/\s+/).filter(Boolean);
  const metadataQuery = (filters.metadataQuery ?? "").trim();
  const matchMode = filters.matchMode ?? "prefix";
  const searchIndex = new Map(txns.map((txn) => [transactionKey(txn), buildTransactionSearchEntry(txn)]));

  return txns.filter((txn) => {
    const index = searchIndex.get(transactionKey(txn));
    if (!index) return false;

    if (categoryQuery) {
      const categoryMatches = index.categoryAccounts.some((account) =>
        matchMode === "prefix" ? account.startsWith(categoryQuery) : account === categoryQuery
      );
      if (!categoryMatches) return false;
    }

    if (searchWords.length > 0 && !searchWords.every((word) => index.text.includes(word))) {
      return false;
    }

    if (metadataQuery) {
      const normalizedMetadataQuery = metadataQuery.toLowerCase();
      if (!/[#:]/.test(normalizedMetadataQuery)) return index.metadata.includes(normalizedMetadataQuery);
      if (!matchesMetadataQuery(txn, metadataQuery)) return false;
    }

    return true;
  });
}
