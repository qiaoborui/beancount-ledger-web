import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { TimeRangePicker } from "./TimeRangePicker";

describe("TimeRangePicker layout", () => {
  it("groups the spacious picker inside one visible segmented boundary", () => {
    const html = renderToString(
      <TimeRangePicker
        range={{ start: "2026-01-01", end: "2027-01-01", preset: "year" }}
        onChange={vi.fn()}
      />,
    );

    expect(html).toContain("md:min-w-80");
    expect(html).toContain("h-14");
    expect(html).toContain("md:h-16");
    expect(html).toContain("md:px-5");
    expect(html).toContain("md:w-12");
    expect(html).toMatch(/data-time-range-control="segmented"[^>]*overflow-hidden[^>]*rounded-lg[^>]*border-lineSoft/);
    expect(html).toMatch(/h-full[^>]*border-r[^>]*aria-label="上一时间段"/);
    expect(html).toMatch(/h-full[^>]*border-l[^>]*aria-label="下一时间段"/);
    expect(html).not.toContain("md:gap-2.5");
  });
});
