#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const baseUrl = (process.env.LEDGER_AGENT_TOOL_BASE_URL || "http://127.0.0.1:3000").replace(/\/+$/, "");
const token = process.env.LEDGER_AGENT_TOOL_TOKEN || "";

if (!token) {
  console.error("LEDGER_AGENT_TOOL_TOKEN is required for the ledger MCP server.");
  process.exit(2);
}

async function callLedger(path, body) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { text };
  }
  if (!response.ok) {
    const message = data && typeof data.error === "string" ? data.error : `ledger tool failed with ${response.status}`;
    throw new Error(message);
  }
  return data;
}

function jsonContent(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  };
}

const server = new McpServer({
  name: "beancount-ledger-tools",
  version: "0.1.0",
});

server.registerTool(
  "list_accounts",
  {
    title: "List Ledger Accounts",
    description: "List Beancount accounts parsed by the Go server. Does not expose raw ledger files.",
    inputSchema: {},
  },
  async () => jsonContent(await callLedger("/internal/agent/accounts")),
);

server.registerTool(
  "query_transactions",
  {
    title: "Query Ledger Transactions",
    description: "Search parsed transactions by date range and optional account, payee, or text. Income transactions are excluded unless includeIncome is true.",
    inputSchema: {
      start: z.string().describe("Inclusive YYYY-MM-DD start date."),
      end: z.string().describe("Exclusive YYYY-MM-DD end date."),
      account: z.string().optional().describe("Exact Beancount account name."),
      accountPrefix: z.string().optional().describe("Account prefix such as Expenses:Food."),
      payee: z.string().optional(),
      text: z.string().optional().describe("Case-insensitive search over payee, narration, tags, metadata, and accounts."),
      limit: z.number().int().min(1).max(200).optional(),
      includeIncome: z.boolean().optional(),
    },
  },
  async (args) => jsonContent(await callLedger("/internal/agent/transactions/query", args)),
);

server.registerTool(
  "summarize_expenses",
  {
    title: "Summarize Expenses",
    description: "Summarize Expenses:* postings by account, date, or payee for a date range.",
    inputSchema: {
      start: z.string().describe("Inclusive YYYY-MM-DD start date."),
      end: z.string().describe("Exclusive YYYY-MM-DD end date."),
      groupBy: z.enum(["account", "date", "payee"]).optional(),
      limit: z.number().int().min(1).max(200).optional(),
    },
  },
  async (args) => jsonContent(await callLedger("/internal/agent/expenses/summary", args)),
);

server.registerTool(
  "validate_entries",
  {
    title: "Validate Entry Drafts",
    description: "Validate proposed Beancount entries against active accounts and return bean text previews. This tool never writes files.",
    inputSchema: {
      entries: z.array(z.object({
        kind: z.string().optional(),
        date: z.string(),
        payee: z.string().optional(),
        narration: z.string().optional(),
        metadata: z.record(z.string(), z.any()).optional(),
        tags: z.array(z.string()).optional(),
        postings: z.array(z.object({
          account: z.string(),
          amount: z.string(),
          currency: z.string().optional(),
        })).optional(),
        account: z.string().optional(),
        amount: z.string().optional(),
        currency: z.string().optional(),
        confidence: z.number().optional(),
        needsReview: z.boolean().optional(),
        questions: z.array(z.string()).optional(),
      })).min(1).max(50),
    },
  },
  async (args) => jsonContent(await callLedger("/internal/agent/entries/validate", args)),
);

const transport = new StdioServerTransport();
await server.connect(transport);
