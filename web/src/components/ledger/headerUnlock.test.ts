import { describe, expect, it } from "vitest";
import { shouldOfferHeaderSensitiveUnlock } from "./headerUnlock";

const baseState = {
  hasPasskey: false,
  passkeyStatusLoaded: false,
  quickUnlockEnabled: false,
  offlineSensitiveUnlockAvailable: false,
  online: true,
  unlocked: false,
};

describe("shouldOfferHeaderSensitiveUnlock", () => {
  it("keeps the header unlock entry visible while passkey status is loading", () => {
    expect(shouldOfferHeaderSensitiveUnlock(baseState)).toBe(true);
  });

  it("hides the header unlock entry after loading confirms no unlock method is available", () => {
    expect(shouldOfferHeaderSensitiveUnlock({ ...baseState, passkeyStatusLoaded: true })).toBe(false);
  });

  it("does not offer unlock while sensitive data is already unlocked", () => {
    expect(shouldOfferHeaderSensitiveUnlock({ ...baseState, hasPasskey: true, unlocked: true })).toBe(false);
  });
});
