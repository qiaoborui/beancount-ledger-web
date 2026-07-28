import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { TimeRangePicker } from "./TimeRangePicker";

describe("TimeRangePicker layout", () => {
  it("keeps a spacious desktop trigger and navigation controls", () => {
    const html = renderToString(
      <TimeRangePicker
        range={{ start: "2026-01-01", end: "2027-01-01", preset: "year" }}
        onChange={vi.fn()}
      />,
    );

    expect(html).toContain("md:min-w-72");
    expect(html).toContain("md:h-14");
    expect(html).toContain("md:w-12");
  });
});
