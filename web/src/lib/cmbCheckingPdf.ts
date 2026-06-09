import * as pdfjs from "pdfjs-dist";
import pdfWorkerUrl from "pdfjs-dist/legacy/build/pdf.worker.mjs?url";
import type { TextItem, TextMarkedContent } from "pdfjs-dist/types/src/display/api";
export { shouldConvertCmbCheckingPdf } from "./cmbCheckingPdfDetection";

const cmbCheckingHeaders = ["记账日期", "货币", "交易金额", "联机余额", "交易摘要", "对手信息", "客户摘要"];

type ColumnRange = {
  title: string;
  colIdx: number;
  xLeft: number;
  xRight: number;
};

function textItems(items: Array<TextItem | TextMarkedContent>): TextItem[] {
  return items.filter((item): item is TextItem => Boolean(`${(item as TextItem)?.str ?? ""}`.trim()));
}

function itemX(item: TextItem) {
  return item.transform[4];
}

function csvCell(cell: string) {
  return cell.includes(",") || cell.includes("\"") || cell.includes("\n") ? `"${cell.replace(/"/g, "\"\"")}"` : cell;
}

function csvLine(row: string[]) {
  return row.map(csvCell).join(",");
}

function tableRow(items: TextItem[][], width: number) {
  return Array.from({ length: width }, (_, index) => (items[index] || []).map((item) => `${item.str || ""}`.trim()).join(""));
}

function columnIndex(item: TextItem, ranges: ColumnRange[]) {
  const x = itemX(item);
  return ranges.find((range) => range.xLeft <= x && range.xRight >= x)?.colIdx;
}

export async function convertCmbCheckingPdfToCsv(file: File): Promise<File> {
  if (!pdfjs.GlobalWorkerOptions.workerSrc) {
    pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerUrl;
  }

  const typedArray = new Uint8Array(await file.arrayBuffer());
  const pdf = await pdfjs.getDocument({ data: typedArray }).promise;
  const allRows: TextItem[][][] = [];
  let headerItems: TextItem[] = [];

  for (let pageNo = 1; pageNo <= pdf.numPages; pageNo++) {
    const page = await pdf.getPage(pageNo);
    const content = await page.getTextContent();
    const allItems = textItems(content.items as Array<TextItem | TextMarkedContent>);
    const pageHeaderItems = cmbCheckingHeaders
      .map((header) => allItems.find((item) => item.str === header))
      .filter((item): item is TextItem => Boolean(item));
    const dateHeader = pageHeaderItems.find((item) => item.str === "记账日期");
    if (!dateHeader) {
      continue;
    }
    if (headerItems.length === 0) {
      headerItems = pageHeaderItems;
    }

    const ranges = pageHeaderItems.map((item, index) => ({
      title: item.str,
      colIdx: index,
      xLeft: itemX(item),
      xRight: (pageHeaderItems[index + 1] ? itemX(pageHeaderItems[index + 1]) : 9999) - 0.01,
    }));
    const isDateColumn = (item: TextItem) =>
      itemX(item) === itemX(dateHeader) && /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(item.str);

    let currentRow: TextItem[][] | null = null;
    for (const item of allItems) {
      if (isDateColumn(item)) {
        currentRow = Array.from({ length: pageHeaderItems.length }, () => []);
        currentRow[0].push(item);
        allRows.push(currentRow);
        continue;
      }
      if (!currentRow) {
        continue;
      }
      const index = columnIndex(item, ranges);
      if (typeof index === "number") {
        currentRow[index].push(item);
      }
    }
  }

  if (headerItems.length === 0 || allRows.length === 0) {
    throw new Error("未从招商银行储蓄卡 PDF 中解析到交易明细");
  }

  const headers = headerItems.map((item) => item.str);
  const csv = [csvLine(headers), ...allRows.map((row) => csvLine(tableRow(row, headers.length)))].join("\n");
  return new File([csv], `${file.name}.csv`, { type: "text/csv;charset=utf-8" });
}
