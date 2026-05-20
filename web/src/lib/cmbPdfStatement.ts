import fs from "node:fs";
import type { PDFDocumentProxy, PDFPageProxy, TextItem } from "pdfjs-dist/types/src/display/api";

/**
 * CMB credit-card PDF parser.
 *
 * Adapted from deb-sig/bill-file-converter's cmb-credit adapter:
 * https://github.com/deb-sig/bill-file-converter/blob/main/src/adapters/cmb-credit/index.ts
 * License: Apache-2.0
 *
 * The important idea is to rebuild the table by PDF text item coordinates instead
 * of splitting extracted text. This preserves empty/missing cells (notably card
 * last-4) and prevents original transaction amount from shifting left.
 */

const ALL_HEADERS = ["交易日", "记账日", "交易摘要", "人民币金额", "卡号末四位", "交易地金额"] as const;
const POSTED_DATE_RE = /^(0[1-9]|1[0-2])\/(0[1-9]|[12][0-9]|3[01])$/;
const DATE_RE = POSTED_DATE_RE;
const MONEY_RE = /^-?\d[\d,]*\.\d{2}(?:\([A-Z]+\))?$/;
const CARD_LAST4_RE = /^\d{4}$/;

type HeaderInfo = {
  title: string;
  headers: string[];
  headerXRanges: { title: string; colIdx: number; xLeft: number; xRight: number }[];
};

type TableCell = string | null;

export type CmbPdfParseResult = {
  csv: string;
  title: string;
  rowCount: number;
  missingCardLast4Count: number;
  warnings: string[];
};

function isTextItem(item: unknown): item is TextItem {
  return Boolean((item as TextItem | undefined)?.str?.trim());
}

function textItemsFromContent(content: Awaited<ReturnType<PDFPageProxy["getTextContent"]>>) {
  return content.items.filter(isTextItem);
}

function textX(item: TextItem) {
  return item.transform[4];
}

function textY(item: TextItem) {
  return item.transform[5];
}

async function loadPdfjs() {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  return pdfjs;
}

function csvCell(value: string) {
  if (/[",\n\r]/.test(value)) return `"${value.replace(/"/g, '""')}"`;
  return value;
}

function csvRow(cells: string[]) {
  return cells.map(csvCell).join(",");
}

async function extractHeaderInfoFromDoc(doc: PDFDocumentProxy): Promise<HeaderInfo> {
  const firstPage = await doc.getPage(1);
  const textContent = await firstPage.getTextContent();
  const allItems = textItemsFromContent(textContent);

  const titleItem = allItems.find((item) => /招商银行信用卡对账单/.test(item.str));
  const headerItems = ALL_HEADERS.map((header) => allItems.find((item) => item.str === header));
  const presentHeaderItems = headerItems.filter((item): item is TextItem => Boolean(item));
  const missingHeaders = ALL_HEADERS.filter((_, index) => !headerItems[index]);

  if (!titleItem) throw new Error("未识别到招商银行信用卡对账单标题");
  if (missingHeaders.length) throw new Error(`未找到招行信用卡 PDF 表头: ${missingHeaders.join(", ")}`);

  const headerXRanges = presentHeaderItems.map((item, index) => ({
    title: item.str,
    colIdx: index,
    xLeft: textX(item),
    xRight: (presentHeaderItems[index + 1] ? textX(presentHeaderItems[index + 1]) : 999) - 0.01,
  }));

  return {
    title: titleItem.str,
    headers: presentHeaderItems.map((item) => item.str),
    headerXRanges,
  };
}

function getItemXIndex(item: TextItem, headerXRanges: HeaderInfo["headerXRanges"]) {
  const x = textX(item);
  const xRange = headerXRanges.find((range) => range.xLeft <= x && range.xRight >= x);
  return xRange?.colIdx;
}

async function extractRowsFromPage(page: PDFPageProxy, headerInfo: HeaderInfo): Promise<TableCell[][]> {
  const textContent = await page.getTextContent();
  const allItems = textItemsFromContent(textContent);

  const postedDateItems = allItems.filter((item) => {
    const xIndex = getItemXIndex(item, headerInfo.headerXRanges);
    return xIndex === 1 && POSTED_DATE_RE.test(item.str.trim());
  });

  const rowYRanges = postedDateItems.map((item, index) => ({
    rowIdx: index,
    yBottom: textY(item) - 1,
    yTop: textY(item) + item.height + 1,
  }));

  const getItemYIndex = (item: TextItem) => {
    const y = textY(item);
    const yRange = rowYRanges.find((range) => range.yBottom <= y && range.yTop >= y);
    return yRange?.rowIdx;
  };

  const table: TableCell[][] = [];
  for (const item of allItems) {
    const xIndex = getItemXIndex(item, headerInfo.headerXRanges);
    const yIndex = getItemYIndex(item);
    if (typeof xIndex === "undefined" || typeof yIndex === "undefined") continue;
    if (!table[yIndex]) table[yIndex] = Array(ALL_HEADERS.length).fill(null);
    const existing = table[yIndex][xIndex];
    const value = item.str.trim();
    table[yIndex][xIndex] = existing ? `${existing}${value}` : value;
  }

  return table.filter((row) => row?.some((cell) => cell && cell.trim()));
}

function looksLikeDataRow(row: string[]) {
  const [transDate, postDate, description, rmbAmount, cardLast4, originalAmount] = row;
  return (
    (transDate === "" || DATE_RE.test(transDate)) &&
    DATE_RE.test(postDate) &&
    Boolean(description) &&
    MONEY_RE.test(rmbAmount) &&
    (cardLast4 === "" || CARD_LAST4_RE.test(cardLast4)) &&
    MONEY_RE.test(originalAmount)
  );
}

function normalizeRow(row: TableCell[]) {
  return Array.from({ length: ALL_HEADERS.length }, (_, index) => (row[index] ?? "").trim());
}

export async function parseCmbCreditPdfToCsv(inputFile: string): Promise<CmbPdfParseResult> {
  const pdfjs = await loadPdfjs();
  const bytes = new Uint8Array(fs.readFileSync(inputFile));
  const loadingTask = pdfjs.getDocument({
    data: bytes,
    disableFontFace: true,
    isEvalSupported: false,
    useWorkerFetch: false,
  });

  const doc = await loadingTask.promise;
  const headerInfo = await extractHeaderInfoFromDoc(doc);
  const rows: string[][] = [];

  for (let pageNo = 1; pageNo <= doc.numPages; pageNo += 1) {
    const page = await doc.getPage(pageNo);
    const pageRows = await extractRowsFromPage(page, headerInfo);
    rows.push(...pageRows.map(normalizeRow));
  }

  const dataRows = rows.filter(looksLikeDataRow);
  const skippedRows = rows.length - dataRows.length;
  const missingCardLast4Count = dataRows.filter((row) => !row[4]).length;
  const warnings: string[] = [];
  if (!dataRows.length) warnings.push("未从招商银行信用卡 PDF 中解析到交易明细。");
  if (missingCardLast4Count) warnings.push(`${missingCardLast4Count} 条交易缺少卡号末四位，已保留空列避免金额错位。`);
  if (skippedRows > 0) warnings.push(`PDF 中有 ${skippedRows} 行表格文本未匹配为交易明细，已跳过。`);

  const csv = [headerInfo.title, csvRow([...ALL_HEADERS]), ...dataRows.map(csvRow)].join("\n");
  return { csv, title: headerInfo.title, rowCount: dataRows.length, missingCardLast4Count, warnings };
}
