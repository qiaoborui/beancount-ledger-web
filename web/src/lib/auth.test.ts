import { afterEach, describe, expect, it } from "vitest";
import { isAuthDisabled } from "./auth";

const previousAuthDisabled = process.env.LEDGER_AUTH_DISABLED;

afterEach(() => {
  if (previousAuthDisabled === undefined) delete process.env.LEDGER_AUTH_DISABLED;
  else process.env.LEDGER_AUTH_DISABLED = previousAuthDisabled;
});

describe("isAuthDisabled", () => {
  it("accepts explicit true-like values", () => {
    for (const value of ["1", "true", "yes", "on"]) {
      process.env.LEDGER_AUTH_DISABLED = value;
      expect(isAuthDisabled()).toBe(true);
    }
  });

  it("keeps authentication enabled by default", () => {
    delete process.env.LEDGER_AUTH_DISABLED;
    expect(isAuthDisabled()).toBe(false);

    process.env.LEDGER_AUTH_DISABLED = "false";
    expect(isAuthDisabled()).toBe(false);
  });
});
