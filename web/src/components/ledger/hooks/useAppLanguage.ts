import { useEffect, useState } from "react";
import i18n, { changeAppLanguage, readLanguage, type SupportedLanguage } from "@/i18n";

export function useAppLanguage() {
  const [language, setLanguageState] = useState<SupportedLanguage>(() => readLanguage());

  useEffect(() => {
    const handleLanguageChanged = (next: string) => {
      setLanguageState((next === "en-US" ? "en-US" : "zh-CN") as SupportedLanguage);
    };
    i18n.on("languageChanged", handleLanguageChanged);
    return () => {
      i18n.off("languageChanged", handleLanguageChanged);
    };
  }, []);

  const setLanguage = (next: SupportedLanguage) => {
    changeAppLanguage(next);
  };

  return { language, setLanguage };
}
