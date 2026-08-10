import { describe, expect, it, vi } from "vitest";
import i18n, { changeAppLanguage, defaultLanguage, readLanguage, supportedLanguages, type SupportedLanguage } from "./index";

describe("i18n bootstrap", () => {
  it("initializes with zh-CN as the default language", () => {
    expect(supportedLanguages).toEqual(["zh-CN", "en-US"]);
    expect(defaultLanguage).toBe("zh-CN");
    expect(i18n.isInitialized).toBe(true);
  });

  it("translates the same key differently across languages", async () => {
    expect(i18n.t("nav.home")).toBe("财务概览");
    await i18n.changeLanguage("en-US");
    expect(i18n.t("nav.home")).toBe("Overview");
  });

  it("returns zh-CN translations for the fallback language", async () => {
    await i18n.changeLanguage("zh-CN");
    expect(i18n.t("app.name")).toBe("我的账本");
  });

  it("exposes the supported languages for the settings UI", () => {
    expect(supportedLanguages as readonly SupportedLanguage[]).toEqual(["zh-CN", "en-US"]);
  });
});

describe("readLanguage with stored preference", () => {
  it("reads en-US from localStorage when set", () => {
    const getItem = vi.fn().mockReturnValue("en-US");
    vi.stubGlobal("window", { localStorage: { getItem } });
    expect(readLanguage()).toBe("en-US");
    vi.unstubAllGlobals();
  });

  it("defaults to zh-CN when nothing is stored", () => {
    const getItem = vi.fn().mockReturnValue(null);
    vi.stubGlobal("window", { localStorage: { getItem } });
    expect(readLanguage()).toBe("zh-CN");
    vi.unstubAllGlobals();
  });
});

describe("changeAppLanguage", () => {
  it("switches the active language back and forth", async () => {
    await changeAppLanguage("en-US");
    expect(i18n.language).toBe("en-US");
    await changeAppLanguage("zh-CN");
    expect(i18n.language).toBe("zh-CN");
  });
});
