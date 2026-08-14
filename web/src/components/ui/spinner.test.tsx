import { readFileSync } from "node:fs";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { DotMatrixLoader } from "./spinner";

describe("DotMatrixLoader", () => {
  it("renders an accessible, configurable 5 by 5 status indicator", () => {
    const html = renderToStaticMarkup(
      <DotMatrixLoader
        aria-label="正在生成账本"
        className="text-brand test-loader"
        data-state="busy"
        size="lg"
      />,
    );

    expect(html).toContain('role="status"');
    expect(html).toContain('aria-label="正在生成账本"');
    expect(html).toContain('data-slot="dot-matrix-loader"');
    expect(html).toContain("dot-matrix-loader--lg text-brand test-loader");
    expect(html).toContain('data-state="busy"');
    expect(html.match(/dot-matrix-loader__dot/g)).toHaveLength(25);
  });

  it("can be decorative when nearby text already owns the status", () => {
    const html = renderToStaticMarkup(<DotMatrixLoader aria-hidden="true" />);

    expect(html).toContain('aria-hidden="true"');
    expect(html).not.toContain('role="status"');
    expect(html).not.toContain("aria-label");
  });

  it("uses a static, legible dot state for reduced motion", () => {
    const css = readFileSync(new URL("../../app/globals.css", import.meta.url), "utf8");
    const reducedMotion = [...css.matchAll(/@media \(prefers-reduced-motion: reduce\) \{[\s\S]*?^\}/gm)]
      .find(([block]) => block.includes(".dot-matrix-loader__dot"))?.[0] ?? "";

    expect(reducedMotion).toContain(".dot-matrix-loader__dot");
    expect(reducedMotion).toContain("animation: none !important");
    expect(reducedMotion).toContain("opacity: 0.72");
    expect(reducedMotion).toContain("transform: none");
  });
});
