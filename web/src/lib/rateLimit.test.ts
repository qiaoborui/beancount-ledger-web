import { afterEach, describe, expect, it } from "vitest";
import { clearRateLimitForTests, rateLimit } from "./rateLimit";

const previousDisabled = process.env.LEDGER_RATE_LIMIT_DISABLED;

afterEach(() => {
  clearRateLimitForTests();
  if (previousDisabled === undefined) delete process.env.LEDGER_RATE_LIMIT_DISABLED;
  else process.env.LEDGER_RATE_LIMIT_DISABLED = previousDisabled;
});

function requestFor(ip: string) {
  return new Request("http://localhost/api/test", { headers: { "x-forwarded-for": ip } });
}

describe("rateLimit", () => {
  it("allows requests until the limit is exceeded", () => {
    const options = { name: "test", limit: 2, windowMs: 60_000 };

    expect(rateLimit(requestFor("192.0.2.1"), options)).toBeNull();
    expect(rateLimit(requestFor("192.0.2.1"), options)).toBeNull();
    expect(rateLimit(requestFor("192.0.2.1"), options)?.status).toBe(429);
    expect(rateLimit(requestFor("192.0.2.2"), options)).toBeNull();
  });

  it("can be disabled for trusted deployments", () => {
    process.env.LEDGER_RATE_LIMIT_DISABLED = "true";

    expect(rateLimit(requestFor("192.0.2.1"), { name: "test", limit: 0, windowMs: 60_000 })).toBeNull();
    expect(rateLimit(requestFor("192.0.2.1"), { name: "test", limit: 1, windowMs: 60_000 })).toBeNull();
    expect(rateLimit(requestFor("192.0.2.1"), { name: "test", limit: 1, windowMs: 60_000 })).toBeNull();
  });
});
