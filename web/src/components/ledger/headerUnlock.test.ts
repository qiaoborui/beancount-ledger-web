import { describe, expect, it } from "vitest";
import { shouldOfferHeaderSensitiveUnlock } from "./headerUnlock";

const baseState = {
  offlineSensitiveUnlockAvailable: false,
  online: true,
  unlocked: false,
};

describe("shouldOfferHeaderSensitiveUnlock", () => {
  it("keeps the header unlock entry visible while passkey status is loading", () => {
    expect(shouldOfferHeaderSensitiveUnlock(baseState)).toBe(true);
  });

  it("keeps the header unlock entry available for the main-password fallback", () => {
    expect(shouldOfferHeaderSensitiveUnlock(baseState)).toBe(true);
  });

  it("does not offer unlock while sensitive data is already unlocked", () => {
    expect(shouldOfferHeaderSensitiveUnlock({ ...baseState, unlocked: true })).toBe(false);
  });

  it("does not offer the online password fallback while fully offline", () => {
    expect(shouldOfferHeaderSensitiveUnlock({ ...baseState, online: false })).toBe(false);
  });
});
