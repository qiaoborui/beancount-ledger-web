import { describe, expect, it } from "vitest";
import { getWebPushPresentation, type WebPushState } from "./useWebPush";

function state(overrides: Partial<WebPushState> = {}): WebPushState {
  return {
    supported: true,
    permission: "default",
    subscribed: false,
    configured: true,
    loading: false,
    error: "",
    ...overrides,
  };
}

describe("getWebPushPresentation", () => {
  it("guides a new user through browser permission", () => {
    expect(getWebPushPresentation(state())).toMatchObject({
      status: "等待授权",
      toggleDisabled: false,
      testAvailable: false,
    });
  });

  it("shows the active subscription and test action", () => {
    expect(getWebPushPresentation(state({ permission: "granted", subscribed: true }))).toMatchObject({
      status: "已开启",
      tone: "success",
      toggleDisabled: false,
      testAvailable: true,
    });
  });

  it("guides users to browser settings after permission is blocked", () => {
    const presentation = getWebPushPresentation(state({ permission: "denied" }));
    expect(presentation.status).toBe("浏览器已阻止");
    expect(presentation.description).toContain("站点设置");
    expect(presentation.toggleDisabled).toBe(true);
  });

  it("keeps the switch disabled until the server is configured", () => {
    expect(getWebPushPresentation(state({ configured: false }))).toMatchObject({
      status: "服务端待配置",
      toggleDisabled: true,
    });
  });
});
