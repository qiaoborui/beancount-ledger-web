import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { TimeRangePicker } from "./TimeRangePicker";

const globalCss = readFileSync(fileURLToPath(new URL("../../app/globals.css", import.meta.url)), "utf8");

describe("TimeRangePicker layout", () => {
  it("keeps the desktop picker compact inside one visible segmented boundary", () => {
    const html = renderToString(
      <TimeRangePicker
        range={{ start: "2026-01-01", end: "2027-01-01", preset: "year" }}
        onChange={vi.fn()}
      />,
    );

    expect(html).toContain("md:min-w-64");
    expect(html).toContain("h-14");
    expect(html).toContain("md:h-12");
    expect(html).toContain("md:px-3");
    expect(html).toContain("md:w-9");
    expect(html).toMatch(/data-time-range-control="segmented"[^>]*overflow-hidden[^>]*rounded-lg[^>]*border-lineSoft/);
    expect(html).toMatch(/h-full[^>]*border-r[^>]*aria-label="上一时间段"/);
    expect(html).toMatch(/h-full[^>]*border-l[^>]*aria-label="下一时间段"/);
    expect(html).toContain("md:gap-2.5");
    expect(html).not.toContain("md:gap-4");
  });

  it("does not let workspace styles override picker button geometry", () => {
    expect(globalCss).not.toMatch(/\.workspace-time-control\s+button/);
  });
});
