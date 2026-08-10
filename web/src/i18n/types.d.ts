import type { TranslationResource } from "./locales/zh-CN";

declare module "i18next" {
  interface CustomTypeOptions {
    defaultNS: "translation";
    resources: {
      translation: TranslationResource;
    };
  }
}
