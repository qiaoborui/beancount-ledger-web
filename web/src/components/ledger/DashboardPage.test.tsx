import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { InteractiveLegend } from "./DashboardPage";

const categorySeries = [
  { account: "Expenses:Housing:Utilities", label: "水电燃气" },
  { account: "Expenses:Food:Groceries", label: "食材" },
  { account: "Expenses:Housing:Property", label: "物业费" },
  { account: "Expenses:Health:Fitness", label: "健身" },
  { account: "Expenses:Food:Meals", label: "日常正餐" },
  { account: "Expenses:Food:Drinks", label: "饮料" },
  { account: "Expenses:Digital:AI", label: "AI 服务" },
  { account: "Expenses:Transport:Taxi", label: "打车" },
];

describe("InteractiveLegend", () => {
  it("shows the complete category legend on wider screens without removing the narrow-screen scroll limit", () => {
    const html = renderToString(
      <InteractiveLegend
        series={categorySeries}
        focusedAccount={null}
        onToggle={vi.fn()}
        expandOnWideScreens
      />,
    );

    expect(html).toContain("max-h-20");
    expect(html).toContain("overflow-y-auto");
    expect(html).toContain("sm:max-h-none");
    expect(html).toContain("sm:overflow-visible");
    expect(html.match(/<button/g)).toHaveLength(categorySeries.length);
  });
});
