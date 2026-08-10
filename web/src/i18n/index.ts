import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import { zhCN } from "./locales/zh-CN";
import { enUS } from "./locales/en-US";

export const supportedLanguages = ["zh-CN", "en-US"] as const;
export type SupportedLanguage = (typeof supportedLanguages)[number];

export const defaultLanguage: SupportedLanguage = "zh-CN";

// Mirrors the storage key used by components/ledger/storage.ts so the i18n
// bootstrap and the settings UI always agree.
const languageStorageKey = "ledger_language";

function readStoredLanguage(): SupportedLanguage {
  if (typeof window === "undefined") return defaultLanguage;
  try {
    return window.localStorage.getItem(languageStorageKey) === "en-US" ? "en-US" : "zh-CN";
  } catch {
    return defaultLanguage;
  }
}

function writeStoredLanguage(language: SupportedLanguage) {
  if (typeof window === "undefined") return;
  try {
    if (language === "zh-CN") window.localStorage.removeItem(languageStorageKey);
    else window.localStorage.setItem(languageStorageKey, language);
  } catch {
    // Ignore private mode / storage quota errors. The in-memory setting still works.
  }
}

function applyDocumentLanguage(language: SupportedLanguage) {
  if (typeof document === "undefined") return;
  document.documentElement.lang = language;
  document.title = i18n.t("app.name", { lng: language });
}

i18n.use(initReactI18next).init({
  resources: {
    "zh-CN": { translation: zhCN },
    "en-US": { translation: enUS },
  },
  lng: readStoredLanguage(),
  fallbackLng: defaultLanguage,
  supportedLngs: [...supportedLanguages],
  interpolation: { escapeValue: false },
  returnNull: false,
  initAsync: false,
});

applyDocumentLanguage(readStoredLanguage());
i18n.on("languageChanged", (language) => {
  applyDocumentLanguage((language === "en-US" ? "en-US" : "zh-CN") as SupportedLanguage);
});

export function changeAppLanguage(language: SupportedLanguage) {
  writeStoredLanguage(language);
  void i18n.changeLanguage(language);
}

export { readStoredLanguage as readLanguage, writeStoredLanguage as writeLanguage };

export default i18n;
