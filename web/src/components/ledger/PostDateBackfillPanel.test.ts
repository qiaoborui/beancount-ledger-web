import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { PostDateBackfillPanel } from "./PostDateBackfillPanel";

describe("PostDateBackfillPanel", () => {
  it("starts as a read-only scan prompt", () => {
    const html = renderToStaticMarkup(createElement(PostDateBackfillPanel, { showToast: vi.fn() }));
    expect(html).toContain('data-postdate-backfill="true"');
    expect(html).not.toContain('role="checkbox"');
  });
});
