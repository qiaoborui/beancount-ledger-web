import { afterEach, describe, expect, it, vi } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { writeApiEndpointSettings } from "@/lib/apiEndpoints";
import { LoginScreen, SensitiveUnlockPanel } from "./AuthScreens";

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => Array.from(values.keys())[index] ?? null,
    get length() {
      return values.size;
    },
  } satisfies Storage;
}

describe("LoginScreen", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("shows the active backend and a recovery entry for switching backends", () => {
    vi.stubGlobal("window", {
      localStorage: memoryStorage(),
      location: { origin: "https://app.example.com" },
      dispatchEvent: vi.fn(),
    } as unknown as Window & typeof globalThis);
    writeApiEndpointSettings({
      activeId: "backup",
      autoSelect: false,
      endpoints: [
        { id: "same-origin", url: "", enabled: true },
        { id: "backup", url: "https://backup.example.com", enabled: true },
      ],
    });

    const html = renderToStaticMarkup(<LoginScreen password="" setPassword={() => {}} passkeyRegistered={false} onLogin={() => {}} onPasskeyLogin={() => {}} />);

    expect(html).toContain("https://backup.example.com");
    expect(html).toContain("切换后端");
  });

  it("offers the main password when no quick unlock method is available", () => {
    const html = renderToStaticMarkup(<SensitiveUnlockPanel passkeyRegistered={false} onUnlock={() => {}} onPasswordUnlock={() => {}} />);

    expect(html).toContain("主密码");
    expect(html).toContain('type="password"');
  });

  it("keeps the main-password fallback visible beside Face ID", () => {
    const html = renderToStaticMarkup(<SensitiveUnlockPanel passkeyRegistered onUnlock={() => {}} onPasswordUnlock={() => {}} />);

    expect(html).toContain("Face ID / Passkey");
    expect(html).toContain("或使用主密码");
  });
});
