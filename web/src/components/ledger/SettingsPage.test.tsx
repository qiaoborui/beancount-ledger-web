import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { SettingsPageProps } from "./SettingsPage";
import { parseSettingsSelectionSearch, settingsCategories, SettingsGroupContent, SettingsNavigation } from "./SettingsPage";

const settingsProps: SettingsPageProps = {
  settings: {
    homePage: "overview",
    showHomeSummaryAmounts: true,
    showAccountBalancesByDefault: true,
    showNetWorthByDefault: false,
    showIncomeStatementByDefault: true,
    valuationCurrency: "CNY",
  },
  commodities: ["USD", "CNY"],
  onChange: vi.fn(),
  themeMode: "system",
  resolvedTheme: "light",
  onThemeModeChange: vi.fn(),
  mobileTabHrefs: ["/home", "/transactions", "/accounts"],
  onMobileTabHrefsChange: vi.fn(),
  sensitiveUnlocked: false,
  quickUnlockEnabled: false,
  quickUnlockMode: "numeric",
  onEnableQuickUnlock: vi.fn(),
  onDisableQuickUnlock: vi.fn(),
  onRegisterPasskey: vi.fn(async () => null),
  onPasskeyRegisteredChange: vi.fn(),
  showToast: vi.fn(),
};

describe("SettingsPage navigation", () => {
  it("restores valid groups from the URL query and falls back safely", () => {
    expect(parseSettingsSelectionSearch("?settings=privacy.passkeys")).toEqual({ category: "privacy", group: "passkeys" });
    expect(parseSettingsSelectionSearch("?view=compact&settings=privacy.runtime")).toEqual({ category: "workspace", group: "appearance" });
    expect(parseSettingsSelectionSearch("?view=compact")).toEqual({ category: "workspace", group: "appearance" });
  });

  it("renders two selected desktop levels, mobile selectors, and pane controls", () => {
    const html = renderToStaticMarkup(
      <SettingsNavigation selection={{ category: "privacy", group: "passkeys" }} onSelect={vi.fn()} />,
    );

    expect(html.match(/aria-current="page"/g)).toHaveLength(2);
    expect(html).toContain('aria-controls="settings-active-pane"');
    expect(html).toContain('id="settings-group-passkeys"');
    expect(html).toContain('value="privacy" selected=""');
    expect(html).toContain('value="passkeys" selected=""');
    expect(html).toContain("隐私与访问");
  });

  it("keeps the existing appearance and visibility controls in focused panes", () => {
    const appearance = renderToStaticMarkup(
      <SettingsGroupContent {...settingsProps} selection={{ category: "workspace", group: "appearance" }} />,
    );
    const visibility = renderToStaticMarkup(
      <SettingsGroupContent {...settingsProps} selection={{ category: "privacy", group: "visibility" }} />,
    );

    expect(appearance).toContain('id="settings-pane-heading-appearance"');
    expect(appearance).toContain('aria-pressed="true"');
    expect(appearance).toContain("跟随系统");
    expect(appearance).toContain("浅色");
    expect(appearance).toContain("深色");
    expect(visibility).toContain('id="show-home-summary-amounts"');
    expect(visibility).toContain('id="show-account-balances-by-default"');
    expect(visibility).toContain('id="show-net-worth-by-default"');
    expect(visibility).toContain('id="show-income-statement-by-default"');
  });

  it("keeps every registered group mounted with a uniquely addressable heading", () => {
    const html = renderToStaticMarkup(
      <SettingsGroupContent {...settingsProps} selection={{ category: "workspace", group: "appearance" }} />,
    );
    const groups = settingsCategories.flatMap((category) => category.groups);

    expect(new Set(groups.map((group) => group.id)).size).toBe(groups.length);
    for (const group of groups) expect(html).toContain(`id="settings-pane-heading-${group.id}"`);
    expect(html).toContain("hidden=\"\"");
  });
});
